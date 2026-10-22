public with sharing class SLTDashboardController {

    // Two-stage ranking keeps CPU bounded while never dropping an urgent case
    // because of its age:
    //   1. Up to QUERY_ROW_CAP open cases are ranked by a calendar-time estimate
    //      (~0.1 ms CPU per case, no BusinessHours calls).
    //   2. The top Max_Rows__c + CANDIDATE_MARGIN candidates (never more than
    //      EXACT_ROW_CAP) get the exact evaluation, which costs ~2.5 ms CPU per
    //      case when business hours apply, and are re-sorted and cut to Max_Rows__c.
    // Not final so tests can shrink them.
    @TestVisible private static Integer QUERY_ROW_CAP    = 10000;
    @TestVisible private static Integer EXACT_ROW_CAP    = 1500;
    @TestVisible private static Integer CANDIDATE_MARGIN = 250;

    // ── Public result types ────────────────────────────────────────────────────

    public class DashboardResult {
        @AuraEnabled public List<CaseRow> cases;
        @AuraEnabled public String        scopeLabel;
        @AuraEnabled public Integer       totalCaseCount;   // open cases ranked in stage 1
        @AuraEnabled public Boolean       isTruncated;      // query hit QUERY_ROW_CAP: more open cases exist
        @AuraEnabled public Decimal       redThresholdMinutes;   // for client-side RAG between refreshes
        @AuraEnabled public Decimal       amberThresholdPercent;
    }

    public class CaseRow {
        @AuraEnabled public String   caseId;
        @AuraEnabled public String   caseNumber;
        @AuraEnabled public String   subject;
        @AuraEnabled public String   ownerName;
        @AuraEnabled public String   status;
        @AuraEnabled public String   milestoneName;
        @AuraEnabled public DateTime targetDate;
        @AuraEnabled public Decimal  timeRemainingMins;
        @AuraEnabled public Boolean  isViolated;
        @AuraEnabled public DateTime completionDate;
        @AuraEnabled public String   ragStatus;
        @AuraEnabled public String   severity;
        @AuraEnabled public Decimal  sltTargetHours;
        @AuraEnabled public Decimal  hoursElapsed;
        @AuraEnabled public Decimal  hoursRemaining;
        @AuraEnabled public String   severityLabel;
        @AuraEnabled public String   severityColor;
        @AuraEnabled public Decimal  severitySortOrder;
        @AuraEnabled public DateTime deadline;
        @AuraEnabled public String   source;
        @AuraEnabled public Boolean  ruleMissing;
        @AuraEnabled public Boolean  usesBusinessHours;
    }

    // ── Entry point ────────────────────────────────────────────────────────────

    // queueId (optional): open cases owned by this queue are added to the scope result.
    @AuraEnabled(cacheable=true)
    public static DashboardResult getActiveCases(String ownerId, String queueId) {
        DashboardResult result = new DashboardResult();
        Set<Id> ownerIds = resolveScope(ownerId, result);
        if (ownerIds != null && String.isNotBlank(queueId)) {
            ownerIds.add(toQueueId(queueId));
        }
        queryCases(ownerIds, result);
        result.redThresholdMinutes   = SLTRuleService.redThresholdMinutes();
        result.amberThresholdPercent = SLTRuleService.amberThresholdPercent();
        return result;
    }

    // Returns the owner Ids in scope, or null for every case in the org.
    private static Set<Id> resolveScope(String ownerId, DashboardResult result) {
        // Admin override: pin the dashboard to a specific user regardless of permissions
        if (String.isNotBlank(ownerId)) {
            result.scopeLabel = 'Filtered View';
            return new Set<Id>{ ownerId };
        }

        Id currentUserId = UserInfo.getUserId();
        Id currentRoleId = UserInfo.getUserRoleId();

        // Director — all cases across the entire org
        if (FeatureManagement.checkPermission('SLT_Scope_All')) {
            result.scopeLabel = 'All Cases';
            return null;
        }

        // Manager — all cases in their subtree (every team beneath them)
        if (FeatureManagement.checkPermission('SLT_Scope_Org')) {
            Set<Id> userIds = currentRoleId != null
                ? getUsersInSubtree(currentRoleId)
                : new Set<Id>();
            userIds.add(currentUserId);
            result.scopeLabel = 'Your Organisation';
            return userIds;
        }

        // Technical Lead — cases for agents in their direct team only
        if (FeatureManagement.checkPermission('SLT_Scope_Team')) {
            Set<Id> userIds = currentRoleId != null
                ? getUsersInDirectSubroles(currentRoleId)
                : new Set<Id>();
            userIds.add(currentUserId);
            result.scopeLabel = 'Your Team';
            return userIds;
        }

        // Agent (SLT_Scope_Own or no scope permission assigned) — own cases only
        result.scopeLabel = 'Your Cases';
        return new Set<Id>{ currentUserId };
    }

    private static Id toQueueId(String queueId) {
        Id qid;
        try {
            qid = Id.valueOf(queueId);
        } catch (StringException e) {
            qid = null;
        }
        if (qid == null || qid.getSObjectType() != Group.SObjectType) {
            AuraHandledException ex = new AuraHandledException('Invalid queue Id: ' + queueId);
            ex.setMessage('Invalid queue Id: ' + queueId);
            throw ex;
        }
        return qid;
    }

    // ── Role hierarchy helpers ─────────────────────────────────────────────────

    // Returns all users in the entire subtree beneath a role (Manager scope)
    private static Set<Id> getUsersInSubtree(Id roleId) {
        Map<Id, List<Id>> childMap  = buildRoleChildMap();
        Set<Id>           subRoleIds = getDescendantRoleIds(roleId, childMap);
        return getUsersInRoles(subRoleIds);
    }

    // Returns all users in roles that are direct children of the given role (TL scope)
    private static Set<Id> getUsersInDirectSubroles(Id roleId) {
        Set<Id> userIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE  UserRoleId IN (SELECT Id FROM UserRole WHERE ParentRoleId = :roleId)
            AND    IsActive = true
            WITH   USER_MODE
        ]) {
            userIds.add(u.Id);
        }
        return userIds;
    }

    private static Map<Id, List<Id>> buildRoleChildMap() {
        Map<Id, List<Id>> childMap = new Map<Id, List<Id>>();
        for (UserRole r : [SELECT Id, ParentRoleId FROM UserRole WHERE ParentRoleId != null WITH USER_MODE]) {
            if (!childMap.containsKey(r.ParentRoleId)) {
                childMap.put(r.ParentRoleId, new List<Id>());
            }
            childMap.get(r.ParentRoleId).add(r.Id);
        }
        return childMap;
    }

    private static Set<Id> getDescendantRoleIds(Id rootRoleId, Map<Id, List<Id>> childMap) {
        Set<Id>  descendants = new Set<Id>();
        List<Id> queue       = new List<Id>{ rootRoleId };
        while (!queue.isEmpty()) {
            Id       current  = queue.remove(0);
            List<Id> children = childMap.get(current);
            if (children != null) {
                for (Id child : children) {
                    if (descendants.add(child)) {
                        queue.add(child);
                    }
                }
            }
        }
        return descendants;
    }

    private static Set<Id> getUsersInRoles(Set<Id> roleIds) {
        Set<Id> userIds = new Set<Id>();
        for (User u : [SELECT Id FROM User WHERE UserRoleId IN :roleIds AND IsActive = true WITH USER_MODE]) {
            userIds.add(u.Id);
        }
        return userIds;
    }

    // ── Query helpers ──────────────────────────────────────────────────────────

    // ownerIds == null → all open cases
    private static void queryCases(Set<Id> ownerIds, DashboardResult result) {
        DateTime now = DateTime.now();

        // Stage 1 — rank every open case in scope by the cheap estimate
        Map<Id, SLTRuleService.MilestoneInfo> windows = SLTRuleService.useCaseMilestones()
            ? loadMilestoneWindows(ownerIds)
            : new Map<Id, SLTRuleService.MilestoneInfo>();
        List<Candidate> ranked = new List<Candidate>();
        if (ownerIds == null) {
            for (List<Case> chunk : [
                SELECT Id, Severity__c, Priority, CreatedDate,
                       First_Response_Date__c, Last_Update_Date__c
                FROM   Case
                WHERE  IsClosed = false
                WITH   USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT  :QUERY_ROW_CAP
            ]) {
                rank(chunk, windows, now, ranked);
            }
        } else {
            for (List<Case> chunk : [
                SELECT Id, Severity__c, Priority, CreatedDate,
                       First_Response_Date__c, Last_Update_Date__c
                FROM   Case
                WHERE  IsClosed = false
                AND    OwnerId IN :ownerIds
                WITH   USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT  :QUERY_ROW_CAP
            ]) {
                rank(chunk, windows, now, ranked);
            }
        }
        result.totalCaseCount = ranked.size();
        result.isTruncated    = ranked.size() >= QUERY_ROW_CAP;

        // Stage 2 — exact evaluation of the top candidates only
        Integer maxRows = SLTRuleService.maxRows();
        Integer rowLimit = maxRows == null ? EXACT_ROW_CAP : Math.min(maxRows, EXACT_ROW_CAP);
        Set<Id> candidateIds = topCandidates(ranked, Math.min(rowLimit + CANDIDATE_MARGIN, EXACT_ROW_CAP));

        List<Case> cases = [
            SELECT Id, CaseNumber, Subject, OwnerId, Owner.Name, Status,
                   Severity__c, Priority, CreatedDate,
                   First_Response_Date__c, Last_Update_Date__c
            FROM   Case
            WHERE  Id IN :candidateIds
            AND    IsClosed = false
            WITH   USER_MODE
        ];
        Map<Id, SLTRuleService.MilestoneInfo> milestones = SLTRuleService.useCaseMilestones()
            ? loadOpenMilestones(candidateIds)
            : new Map<Id, SLTRuleService.MilestoneInfo>();

        result.cases = sortAndLimit(buildRows(cases, milestones, now), rowLimit);
    }

    private static void rank(List<Case> chunk, Map<Id, SLTRuleService.MilestoneInfo> windows,
                             DateTime now, List<Candidate> ranked) {
        for (Case c : chunk) {
            SLTRuleService.Result r = SLTRuleService.estimate(toInput(c, windows.get(c.Id)), now);
            ranked.add(new Candidate(c.Id, r.remainingMinutes));
        }
    }

    // The `count` most urgent candidates (nulls — no rule — last). Uses a native
    // Decimal sort to find the cut-off instead of sorting objects, which costs
    // ~1 s CPU at 10,000 rows versus a few ms.
    @TestVisible
    private static Set<Id> topCandidates(List<Candidate> ranked, Integer count) {
        Set<Id> ids = new Set<Id>();
        List<Decimal> values = new List<Decimal>();
        for (Candidate c : ranked) {
            if (c.remainingMinutes != null) values.add(c.remainingMinutes);
        }
        values.sort();

        if (values.size() > count) {
            Decimal cutoff = values[count - 1];
            for (Candidate c : ranked) {
                if (c.remainingMinutes != null && c.remainingMinutes < cutoff) ids.add(c.caseId);
            }
            for (Candidate c : ranked) {
                if (ids.size() >= count) break;
                if (c.remainingMinutes == cutoff) ids.add(c.caseId);
            }
        } else {
            for (Candidate c : ranked) {
                if (c.remainingMinutes != null) ids.add(c.caseId);
            }
            for (Candidate c : ranked) {
                if (ids.size() >= count) break;
                if (c.remainingMinutes == null) ids.add(c.caseId);
            }
        }
        return ids;
    }

    @TestVisible
    private class Candidate {
        final Id      caseId;
        final Decimal remainingMinutes;
        @TestVisible
        Candidate(Id caseId, Decimal remainingMinutes) {
            this.caseId           = caseId;
            this.remainingMinutes = remainingMinutes;
        }
    }

    // Earliest-due open milestone window (start/target only) per open case in scope,
    // for stage 1 ranking. Queried dynamically so the package does not depend on
    // Entitlement Management being enabled in the org.
    private static Map<Id, SLTRuleService.MilestoneInfo> loadMilestoneWindows(Set<Id> ownerIds) {
        Map<Id, SLTRuleService.MilestoneInfo> byCase = new Map<Id, SLTRuleService.MilestoneInfo>();
        if (!hasCaseMilestones()) return byCase;

        String soql = 'SELECT CaseId, StartDate, TargetDate FROM CaseMilestone ' +
                      'WHERE IsCompleted = false AND TargetDate != null AND Case.IsClosed = false ' +
                      (ownerIds == null ? '' : 'AND Case.OwnerId IN :ownerIds ') +
                      'ORDER BY TargetDate ASC LIMIT :rowCap';
        Map<String, Object> binds = new Map<String, Object>{ 'rowCap' => QUERY_ROW_CAP };
        if (ownerIds != null) binds.put('ownerIds', ownerIds);
        for (SObject rec : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            Id caseId = (Id) rec.get('CaseId');
            if (byCase.containsKey(caseId)) continue;
            SLTRuleService.MilestoneInfo m = new SLTRuleService.MilestoneInfo();
            m.startDate  = (DateTime) rec.get('StartDate');
            m.targetDate = (DateTime) rec.get('TargetDate');
            byCase.put(caseId, m);
        }
        return byCase;
    }

    // Earliest-due open CaseMilestone per candidate case, with display fields.
    private static Map<Id, SLTRuleService.MilestoneInfo> loadOpenMilestones(Set<Id> caseIds) {
        if (caseIds.isEmpty() || !hasCaseMilestones()) {
            return new Map<Id, SLTRuleService.MilestoneInfo>();
        }
        return mapMilestones(Database.queryWithBinds(
            'SELECT CaseId, StartDate, TargetDate, CompletionDate, IsCompleted, IsViolated, MilestoneType.Name ' +
            'FROM CaseMilestone ' +
            'WHERE CaseId IN :caseIds AND IsCompleted = false AND TargetDate != null ' +
            'ORDER BY TargetDate ASC',
            new Map<String, Object>{ 'caseIds' => caseIds },
            AccessLevel.USER_MODE
        ));
    }

    private static Boolean hasCaseMilestones() {
        return Schema.getGlobalDescribe().containsKey('CaseMilestone');
    }

    @TestVisible
    private static Map<Id, SLTRuleService.MilestoneInfo> mapMilestones(List<SObject> records) {
        Map<Id, SLTRuleService.MilestoneInfo> byCase = new Map<Id, SLTRuleService.MilestoneInfo>();
        for (SObject rec : records) {
            Id caseId = (Id) rec.get('CaseId');
            if (byCase.containsKey(caseId)) continue;

            SLTRuleService.MilestoneInfo m = new SLTRuleService.MilestoneInfo();
            SObject milestoneType = rec.getSObject('MilestoneType');
            m.name           = milestoneType != null ? (String) milestoneType.get('Name') : null;
            m.startDate      = (DateTime) rec.get('StartDate');
            m.targetDate     = (DateTime) rec.get('TargetDate');
            m.completionDate = (DateTime) rec.get('CompletionDate');
            m.isCompleted    = rec.get('IsCompleted') == true;
            m.isViolated     = rec.get('IsViolated') == true;
            byCase.put(caseId, m);
        }
        return byCase;
    }

    private static SLTRuleService.CaseInput toInput(Case c, SLTRuleService.MilestoneInfo m) {
        SLTRuleService.CaseInput input = new SLTRuleService.CaseInput();
        input.severity          = c.Severity__c;
        input.priority          = c.Priority;
        input.createdDate       = c.CreatedDate;
        input.firstResponseDate = c.First_Response_Date__c;
        input.lastUpdateDate    = c.Last_Update_Date__c;
        input.milestone         = m;
        return input;
    }

    private static List<CaseRow> buildRows(List<Case> cases,
                                           Map<Id, SLTRuleService.MilestoneInfo> milestones,
                                           DateTime now) {
        List<CaseRow> rows = new List<CaseRow>();
        for (Case c : cases) {
            SLTRuleService.MilestoneInfo m = milestones.get(c.Id);
            SLTRuleService.Result r = SLTRuleService.evaluate(toInput(c, m), now);

            CaseRow row           = new CaseRow();
            row.caseId            = c.Id;
            row.caseNumber        = c.CaseNumber;
            row.subject           = c.Subject;
            row.ownerName         = c.Owner.Name;
            row.status            = c.Status;
            row.severity          = r.severity;
            row.severityLabel     = r.severityLabel;
            row.severityColor     = r.severityColor;
            row.severitySortOrder = r.severitySortOrder;
            row.ragStatus         = r.ragStatus;
            row.sltTargetHours    = toHours(r.targetMinutes);
            row.hoursElapsed      = toHours(r.elapsedMinutes);
            row.hoursRemaining    = toHours(r.remainingMinutes);
            row.timeRemainingMins = r.remainingMinutes;
            row.deadline          = r.deadline;
            row.source            = r.source;
            row.ruleMissing       = r.ruleMissing;
            row.usesBusinessHours = r.usesBusinessHours;

            if (r.source == SLTRuleService.SOURCE_MILESTONE) {
                row.milestoneName  = m.name;
                row.targetDate     = m.targetDate;
                row.completionDate = m.completionDate;
                row.isViolated     = m.isViolated;
            } else {
                row.milestoneName  = r.phase;
                row.isViolated     = r.isBreached;
            }
            rows.add(row);
        }
        return rows;
    }

    private static Decimal toHours(Decimal minutes) {
        return minutes == null ? null : (minutes / 60).setScale(2);
    }

    // Most urgent first (breached at the top); rows without a rule go last.
    private static List<CaseRow> sortAndLimit(List<CaseRow> rows, Integer rowLimit) {
        List<RowByUrgency> sortable = new List<RowByUrgency>();
        for (CaseRow row : rows) {
            sortable.add(new RowByUrgency(row));
        }
        sortable.sort();

        List<CaseRow> sorted = new List<CaseRow>();
        for (Integer i = 0; i < Math.min(rowLimit, sortable.size()); i++) {
            sorted.add(sortable[i].row);
        }
        return sorted;
    }

    private class RowByUrgency implements Comparable {
        final CaseRow row;
        RowByUrgency(CaseRow row) { this.row = row; }

        public Integer compareTo(Object other) {
            return compareRemaining(row.timeRemainingMins, ((RowByUrgency) other).row.timeRemainingMins);
        }
    }

    // Ascending remaining minutes, nulls (no rule) last
    private static Integer compareRemaining(Decimal a, Decimal b) {
        if (a == b)    return 0;
        if (a == null) return 1;
        if (b == null) return -1;
        return a < b ? -1 : 1;
    }
}
