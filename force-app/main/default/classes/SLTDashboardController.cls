public with sharing class SLTDashboardController {

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
    }

    // ── Entry point ────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static DashboardResult getActiveCases(String ownerId) {
        DashboardResult result = new DashboardResult();

        // Admin override: pin the dashboard to a specific user regardless of permissions
        if (String.isNotBlank(ownerId)) {
            result.cases      = queryCases(new Set<Id>{ ownerId });
            result.scopeLabel = 'Filtered View';
            return result;
        }

        Id currentUserId = UserInfo.getUserId();
        Id currentRoleId = UserInfo.getUserRoleId();

        // Director — all cases across the entire org
        if (FeatureManagement.checkPermission('SLT_Scope_All')) {
            result.cases      = queryAllCases();
            result.scopeLabel = 'All Cases';
            return result;
        }

        // Manager — all cases in their subtree (every team beneath them)
        if (FeatureManagement.checkPermission('SLT_Scope_Org')) {
            Set<Id> userIds = currentRoleId != null
                ? getUsersInSubtree(currentRoleId)
                : new Set<Id>();
            userIds.add(currentUserId);
            result.cases      = queryCases(userIds);
            result.scopeLabel = 'Your Organisation';
            return result;
        }

        // Technical Lead — cases for agents in their direct team only
        if (FeatureManagement.checkPermission('SLT_Scope_Team')) {
            Set<Id> userIds = currentRoleId != null
                ? getUsersInDirectSubroles(currentRoleId)
                : new Set<Id>();
            userIds.add(currentUserId);
            result.cases      = queryCases(userIds);
            result.scopeLabel = 'Your Team';
            return result;
        }

        // Agent (SLT_Scope_Own or no scope permission assigned) — own cases only
        result.cases      = queryCases(new Set<Id>{ currentUserId });
        result.scopeLabel = 'Your Cases';
        return result;
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
        ]) {
            userIds.add(u.Id);
        }
        return userIds;
    }

    private static Map<Id, List<Id>> buildRoleChildMap() {
        Map<Id, List<Id>> childMap = new Map<Id, List<Id>>();
        for (UserRole r : [SELECT Id, ParentRoleId FROM UserRole WHERE ParentRoleId != null]) {
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
        for (User u : [SELECT Id FROM User WHERE UserRoleId IN :roleIds AND IsActive = true]) {
            userIds.add(u.Id);
        }
        return userIds;
    }

    // ── Query helpers ──────────────────────────────────────────────────────────

    private static List<CaseRow> queryCases(Set<Id> ownerIds) {
        return buildRows([
            SELECT Id, CaseNumber, Subject,
                   OwnerId, Owner.Name, Status,
                   Severity__c, Milestone_Type__c,
                   SLT_Target_Hours__c, Hours_Elapsed__c,
                   Hours_Remaining__c, SLT_RAG_Status__c,
                   (SELECT MilestoneType.Name, TargetDate, CompletionDate, IsViolated
                    FROM CaseMilestones
                    ORDER BY TargetDate ASC NULLS LAST
                    LIMIT 1)
            FROM   Case
            WHERE  Status != 'Closed'
            AND    OwnerId IN :ownerIds
            ORDER BY Hours_Remaining__c ASC NULLS LAST
            LIMIT  1000
        ]);
    }

    private static List<CaseRow> queryAllCases() {
        return buildRows([
            SELECT Id, CaseNumber, Subject,
                   OwnerId, Owner.Name, Status,
                   Severity__c, Milestone_Type__c,
                   SLT_Target_Hours__c, Hours_Elapsed__c,
                   Hours_Remaining__c, SLT_RAG_Status__c,
                   (SELECT MilestoneType.Name, TargetDate, CompletionDate, IsViolated
                    FROM CaseMilestones
                    ORDER BY TargetDate ASC NULLS LAST
                    LIMIT 1)
            FROM   Case
            WHERE  Status != 'Closed'
            ORDER BY Hours_Remaining__c ASC NULLS LAST
            LIMIT  1000
        ]);
    }

    private static List<CaseRow> buildRows(List<Case> cases) {
        List<CaseRow> rows = new List<CaseRow>();
        for (Case c : cases) {
            CaseRow row        = new CaseRow();
            row.caseId         = c.Id;
            row.caseNumber     = c.CaseNumber;
            row.subject        = c.Subject;
            row.ownerName      = c.Owner.Name;
            row.status         = c.Status;
            row.ragStatus      = c.SLT_RAG_Status__c;
            row.severity       = c.Severity__c;
            row.sltTargetHours = c.SLT_Target_Hours__c;
            row.hoursElapsed   = c.Hours_Elapsed__c;
            row.hoursRemaining = c.Hours_Remaining__c;

            if (c.CaseMilestones != null && !c.CaseMilestones.isEmpty()) {
                CaseMilestone m    = c.CaseMilestones[0];
                row.milestoneName  = m.MilestoneType.Name;
                row.targetDate     = m.TargetDate;
                row.completionDate = m.CompletionDate;
                row.isViolated     = m.IsViolated;
                if (m.TargetDate != null) {
                    row.timeRemainingMins = (m.TargetDate.getTime() - DateTime.now().getTime()) / 60000.0;
                }
            } else {
                row.milestoneName     = c.Milestone_Type__c;
                row.isViolated        = c.Hours_Remaining__c != null && c.Hours_Remaining__c <= 0;
                row.timeRemainingMins = c.Hours_Remaining__c != null ? c.Hours_Remaining__c * 60 : null;
            }
            rows.add(row);
        }
        return rows;
    }
}
