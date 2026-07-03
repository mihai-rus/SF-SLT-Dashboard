@isTest
private class SLTDashboardControllerTest {

    // ── Helpers ────────────────────────────────────────────────────────────────

    private static User makeUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            FirstName         = 'SLT',
            LastName          = 'Test',
            Email             = alias + '@slt-test.example.com',
            Username          = alias + '@slt-test.example.com',
            Alias             = alias.left(8),
            TimeZoneSidKey    = 'America/New_York',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );
    }

    private static User makeUserWithRole(String alias, Id roleId) {
        User u = makeUser(alias);
        u.UserRoleId = roleId;
        return u;
    }

    private static Case makeCase(String subject, String severity,
                                 String milestone, String status, Id ownerId) {
        return new Case(
            Subject           = subject,
            Severity__c       = severity,
            Milestone_Type__c = milestone,
            Status            = status,
            OwnerId           = ownerId
        );
    }

    private static void assignPermissionSet(Id userId, String permSetName) {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
    }

    // Creates a minimal 2-level role hierarchy: parent → child
    private static List<UserRole> makeTwoLevelRoles() {
        UserRole parent = new UserRole(Name = 'SLT Parent Role', DeveloperName = 'SLT_Parent_Test');
        insert parent;
        UserRole child = new UserRole(Name = 'SLT Child Role', DeveloperName = 'SLT_Child_Test',
                                      ParentRoleId = parent.Id);
        insert child;
        return new List<UserRole>{ parent, child };
    }

    // ── Override filter tests ──────────────────────────────────────────────────

    @isTest
    static void overrideFilterExcludesClosedCases() {
        User u = makeUser('sltAll');
        insert u;

        insert new List<Case>{
            makeCase('Open S1',   'S1', 'First Response', 'New',    u.Id),
            makeCase('Open S2',   'S2', 'Update',         'New',    u.Id),
            makeCase('Closed S1', 'S1', 'First Response', 'Closed', u.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Filtered View', result.scopeLabel);
        for (SLTDashboardController.CaseRow row : result.cases) {
            System.assertNotEquals('Closed', row.status,
                'Closed cases must be excluded');
        }
    }

    @isTest
    static void overrideFilterIsolatesByOwner() {
        User ownerA = makeUser('sltOwnerA');
        User ownerB = makeUser('sltOwnerB');
        insert new List<User>{ ownerA, ownerB };

        insert new List<Case>{
            makeCase('Owner A Case', 'S1', 'First Response', 'New', ownerA.Id),
            makeCase('Owner B Case', 'S3', 'Update',         'New', ownerB.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(ownerA.Id);
        Test.stopTest();

        System.assertEquals('Filtered View', result.scopeLabel);
        System.assert(result.cases.size() >= 1);
    }

    @isTest
    static void blankOwnerIdUsesPermissionBasedScope() {
        User u = makeUser('sltBlank');
        insert u;
        insert makeCase('Blank Test', 'S2', 'Update', 'New', u.Id);

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases('');
        Test.stopTest();

        System.assertNotEquals('Filtered View', result.scopeLabel,
            'Blank ownerId should use permission-based scope, not override');
    }

    // ── CaseRow field tests ────────────────────────────────────────────────────

    @isTest
    static void caseRowHasAllRequiredFields() {
        User u = makeUser('sltFields');
        insert u;
        insert makeCase('Field Check', 'S2', 'First Response', 'In Progress', u.Id);

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id);
        Test.stopTest();

        System.assertEquals(1, result.cases.size());
        SLTDashboardController.CaseRow row = result.cases[0];

        System.assertNotEquals(null, row.caseId,    'caseId must be set');
        System.assertNotEquals(null, row.caseNumber, 'caseNumber must be set');
        System.assertNotEquals(null, row.subject,    'subject must be set');
        System.assertNotEquals(null, row.ownerName,  'ownerName must be set');
        System.assertNotEquals(null, row.status,     'status must be set');
        System.assertEquals('S2',             row.severity);
        System.assertEquals('First Response', row.milestoneName);
    }

    @isTest
    static void casesOrderedByHoursRemainingAscending() {
        User u = makeUser('sltOrder');
        insert u;

        insert new List<Case>{
            makeCase('Case Alpha', 'S1', 'First Response', 'New', u.Id),
            makeCase('Case Beta',  'S1', 'First Response', 'New', u.Id),
            makeCase('Case Gamma', 'S1', 'First Response', 'New', u.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id);
        Test.stopTest();

        System.assertEquals(3, result.cases.size());
        Decimal prev = null;
        for (SLTDashboardController.CaseRow row : result.cases) {
            if (prev != null && row.hoursRemaining != null) {
                System.assert(row.hoursRemaining >= prev,
                    'Cases must be ordered ASC by hoursRemaining');
            }
            if (row.hoursRemaining != null) prev = row.hoursRemaining;
        }
    }

    @isTest
    static void noActiveCasesReturnsEmptyList() {
        User u = makeUser('sltEmpty');
        insert u;

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(0, result.cases.size());
    }

    @isTest
    static void allMilestoneTypesAccepted() {
        User u = makeUser('sltMilestone');
        insert u;

        insert new List<Case>{
            makeCase('FR Case',  'S1', 'First Response', 'New', u.Id),
            makeCase('Upd Case', 'S2', 'Update',         'New', u.Id),
            makeCase('Res Case', 'S3', 'Resolution',     'New', u.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id);
        Test.stopTest();

        System.assertEquals(3, result.cases.size());
        Set<String> milestones = new Set<String>();
        for (SLTDashboardController.CaseRow row : result.cases) {
            milestones.add(row.milestoneName);
        }
        System.assert(milestones.contains('First Response'));
        System.assert(milestones.contains('Update'));
        System.assert(milestones.contains('Resolution'));
    }

    // ── Permission-based scope tests ───────────────────────────────────────────

    @isTest
    static void noScopePermissionDefaultsToOwnCases() {
        User u = makeUser('sltNoScope');
        insert u;
        insert makeCase('Own Case', 'S2', 'First Response', 'New', u.Id);

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(u) {
            result = SLTDashboardController.getActiveCases(null);
        }
        Test.stopTest();

        System.assertEquals('Your Cases', result.scopeLabel);
        System.assertEquals(1, result.cases.size());
    }

    @isTest
    static void scopeOwnShowsOnlyUsersCases() {
        List<UserRole> roles;
        User agent1;
        User agent2;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles  = makeTwoLevelRoles();
            agent1 = makeUserWithRole('sltAgt1', roles[1].Id);
            agent2 = makeUserWithRole('sltAgt2', roles[1].Id);
            insert new List<User>{ agent1, agent2 };
            assignPermissionSet(agent1.Id, 'SLTScope_Own');
        }

        insert new List<Case>{
            makeCase('Agent1 Case', 'S1', 'First Response', 'New', agent1.Id),
            makeCase('Agent2 Case', 'S2', 'Update',         'New', agent2.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(agent1) {
            result = SLTDashboardController.getActiveCases(null);
        }
        Test.stopTest();

        System.assertEquals('Your Cases', result.scopeLabel);
        System.assertEquals(1, result.cases.size());
        System.assertEquals('Agent1 Case', result.cases[0].subject);
    }

    @isTest
    static void scopeTeamShowsDirectSubroleUsers() {
        List<UserRole> roles;
        User tl;
        User agent1;
        User agent2;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles  = makeTwoLevelRoles();
            tl     = makeUserWithRole('sltTL',   roles[0].Id);
            agent1 = makeUserWithRole('sltAgt3', roles[1].Id);
            agent2 = makeUserWithRole('sltAgt4', roles[1].Id);
            insert new List<User>{ tl, agent1, agent2 };
            assignPermissionSet(tl.Id, 'SLTScope_Team');
        }

        insert new List<Case>{
            makeCase('TL Case',    'S1', 'First Response', 'New', tl.Id),
            makeCase('Agent3 Case','S2', 'Update',         'New', agent1.Id),
            makeCase('Agent4 Case','S3', 'Resolution',     'New', agent2.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(tl) {
            result = SLTDashboardController.getActiveCases(null);
        }
        Test.stopTest();

        System.assertEquals('Your Team', result.scopeLabel);
        System.assertEquals(3, result.cases.size(),
            'TL should see own case + both agent cases');
    }

    @isTest
    static void scopeOrgShowsEntireSubtree() {
        List<UserRole> roles;
        User manager;
        User agent;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles   = makeTwoLevelRoles();
            manager = makeUserWithRole('sltMgr',  roles[0].Id);
            agent   = makeUserWithRole('sltAgt5', roles[1].Id);
            insert new List<User>{ manager, agent };
            assignPermissionSet(manager.Id, 'SLTScope_Org');
        }

        insert new List<Case>{
            makeCase('Manager Case', 'S1', 'First Response', 'New', manager.Id),
            makeCase('Agent5 Case',  'S2', 'Update',         'New', agent.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(manager) {
            result = SLTDashboardController.getActiveCases(null);
        }
        Test.stopTest();

        System.assertEquals('Your Organisation', result.scopeLabel);
        System.assertEquals(2, result.cases.size(),
            'Manager should see own case + agent case');
    }

    @isTest
    static void scopeAllShowsEveryCase() {
        List<UserRole> roles;
        User director;
        User agent;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles    = makeTwoLevelRoles();
            director = makeUserWithRole('sltDir',  roles[0].Id);
            agent    = makeUserWithRole('sltAgt6', roles[1].Id);
            insert new List<User>{ director, agent };
            assignPermissionSet(director.Id, 'SLTScope_All');
        }

        insert new List<Case>{
            makeCase('Director Case', 'S1', 'First Response', 'New', director.Id),
            makeCase('Agent6 Case',   'S3', 'Update',         'New', agent.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(director) {
            result = SLTDashboardController.getActiveCases(null);
        }
        Test.stopTest();

        System.assertEquals('All Cases', result.scopeLabel);
        System.assert(result.cases.size() >= 2,
            'Director should see all open cases in the org');
    }
}
