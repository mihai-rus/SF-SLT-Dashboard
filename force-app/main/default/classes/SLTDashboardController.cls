public with sharing class SLTDashboardController {

    // Upper bound on open cases evaluated per request. Rows are sorted by urgency
    // in Apex and then cut to SLT_Setting__mdt.Max_Rows__c, so this must stay
    // above Max_Rows__c. Sized for the worst case: every rule on business hours
    // costs ~2.5 ms CPU per case (BusinessHours.add + diff) against the 10 s limit.
    @TestVisible
    private static final Integer QUERY_ROW_CAP = 1500;

    // ── Public result types ────────────────────────────────────────────────────

    public class DashboardResult {
        @AuraEnabled public List<CaseRow> cases;
        @AuraEnabled public String        scopeLabel;
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
        result.cases = queryCases(ownerIds);
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
    private static List<CaseRow> queryCases(Set<Id> ownerIds) {
        List<Case> cases = ownerIds == null
            ? [
                SELECT Id, CaseNumber, Subject, OwnerId, Owner.Name, Status,
                       Severity__c, Priority, CreatedDate,
                       First_Response_Date__c, Last_Update_Date__c
                FROM   Case
                WHERE  IsClosed = false
                WITH   USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT  :QUERY_ROW_CAP
            ]
            : [
                SELECT Id, CaseNumber, Subject, OwnerId, Owner.Name, Status,
                       Severity__c, Priority, CreatedDate,
                       First_Response_Date__c, Last_Update_Date__c
                FROM   Case
                WHERE  IsClosed = false
                AND    OwnerId IN :ownerIds
                WITH   USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT  :QUERY_ROW_CAP
            ];

        Map<Id, SLTRuleService.MilestoneInfo> milestones = SLTRuleService.useCaseMilestones()
            ? loadOpenMilestones(new Map<Id, Case>(cases).keySet())
            : new Map<Id, SLTRuleService.MilestoneInfo>();

        return sortAndLimit(buildRows(cases, milestones));
    }

    // Earliest-due open CaseMilestone per case. Queried dynamically so the package
    // does not depend on Entitlement Management being enabled in the org.
    private static Map<Id, SLTRuleService.MilestoneInfo> loadOpenMilestones(Set<Id> caseIds) {
        if (caseIds.isEmpty() || !Schema.getGlobalDescribe().containsKey('CaseMilestone')) {
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

    private static List<CaseRow> buildRows(List<Case> cases,
                                           Map<Id, SLTRuleService.MilestoneInfo> milestones) {
        DateTime      now  = DateTime.now();
        List<CaseRow> rows = new List<CaseRow>();
        for (Case c : cases) {
            SLTRuleService.MilestoneInfo m = milestones.get(c.Id);

            SLTRuleService.CaseInput input = new SLTRuleService.CaseInput();
            input.severity          = c.Severity__c;
            input.priority          = c.Priority;
            input.createdDate       = c.CreatedDate;
            input.firstResponseDate = c.First_Response_Date__c;
            input.lastUpdateDate    = c.Last_Update_Date__c;
            input.milestone         = m;
            SLTRuleService.Result r = SLTRuleService.evaluate(input, now);

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
    private static List<CaseRow> sortAndLimit(List<CaseRow> rows) {
        List<RowByUrgency> sortable = new List<RowByUrgency>();
        for (CaseRow row : rows) {
            sortable.add(new RowByUrgency(row));
        }
        sortable.sort();

        Integer maxRows = SLTRuleService.maxRows();
        Integer size    = maxRows == null ? sortable.size() : Math.min(maxRows, sortable.size());
        List<CaseRow> sorted = new List<CaseRow>();
        for (Integer i = 0; i < size; i++) {
            sorted.add(sortable[i].row);
        }
        return sorted;
    }

    private class RowByUrgency implements Comparable {
        final CaseRow row;
        RowByUrgency(CaseRow row) { this.row = row; }

        public Integer compareTo(Object other) {
            Decimal a = row.timeRemainingMins;
            Decimal b = ((RowByUrgency) other).row.timeRemainingMins;
            if (a == b)    return 0;
            if (a == null) return 1;
            if (b == null) return -1;
            return a < b ? -1 : 1;
        }
    }
}
