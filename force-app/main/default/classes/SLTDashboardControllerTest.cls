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

    // Every dashboard user needs base access; queries run in user mode
    private static void grantDashboardAccess(List<User> users) {
        for (User u : users) {
            assignPermissionSet(u.Id, 'SLTDashboardAccess');
        }
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

    private static List<String> subjects(SLTDashboardController.DashboardResult result) {
        List<String> out = new List<String>();
        for (SLTDashboardController.CaseRow row : result.cases) {
            out.add(row.subject);
        }
        return out;
    }

    // ── Override filter tests ──────────────────────────────────────────────────

    @isTest
    static void overrideFilterExcludesClosedCases() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltAll');
        insert u;

        insert new List<Case>{
            makeCase('Open S1',   'S1', 'First Response', 'New',    u.Id),
            makeCase('Open S2',   'S2', 'Update',         'New',    u.Id),
            makeCase('Closed S1', 'S1', 'First Response', 'Closed', u.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Filtered View', result.scopeLabel);
        System.assertEquals(2, result.cases.size(), 'Closed cases must be excluded');
        for (SLTDashboardController.CaseRow row : result.cases) {
            System.assertNotEquals('Closed', row.status,
                'Closed cases must be excluded');
        }
    }

    @isTest
    static void overrideFilterIsolatesByOwner() {
        SLTTestFactory.useDefaultConfig();
        User ownerA = makeUser('sltOwnerA');
        User ownerB = makeUser('sltOwnerB');
        insert new List<User>{ ownerA, ownerB };

        insert new List<Case>{
            makeCase('Owner A Case', 'S1', 'First Response', 'New', ownerA.Id),
            makeCase('Owner B Case', 'S3', 'Update',         'New', ownerB.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(ownerA.Id, null);
        Test.stopTest();

        System.assertEquals('Filtered View', result.scopeLabel);
        System.assertEquals(new List<String>{ 'Owner A Case' }, subjects(result));
    }

    @isTest
    static void blankOwnerIdUsesPermissionBasedScope() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltBlank');
        insert u;
        insert makeCase('Blank Test', 'S2', 'Update', 'New', u.Id);

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases('', '');
        Test.stopTest();

        System.assertNotEquals('Filtered View', result.scopeLabel,
            'Blank ownerId should use permission-based scope, not override');
    }

    // ── Queue tests ────────────────────────────────────────────────────────────

    @isTest
    static void queueIdAddsQueueOwnedCases() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltQueue');
        Group queue = new Group(Name = 'SLT Test Queue', DeveloperName = 'SLT_Test_Queue', Type = 'Queue');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert queue;
            insert new QueueSObject(QueueId = queue.Id, SobjectType = 'Case');
        }

        insert new List<Case>{
            makeCase('User Case',  'S2', 'First Response', 'New',    u.Id),
            makeCase('Queue Case', 'S1', 'First Response', 'New',    queue.Id),
            makeCase('Closed Q',   'S1', 'First Response', 'Closed', queue.Id)
        };

        Test.startTest();
        SLTDashboardController.DashboardResult withQueue =
            SLTDashboardController.getActiveCases(u.Id, queue.Id);
        SLTDashboardController.DashboardResult withoutQueue =
            SLTDashboardController.getActiveCases(u.Id, null);
        Test.stopTest();

        System.assertEquals(new List<String>{ 'Queue Case', 'User Case' }, subjects(withQueue));
        System.assertEquals(new List<String>{ 'User Case' }, subjects(withoutQueue));
    }

    @isTest
    static void invalidQueueIdThrows() {
        SLTTestFactory.useDefaultConfig();
        for (String bad : new List<String>{ 'not-an-id', UserInfo.getUserId() }) {
            try {
                SLTDashboardController.getActiveCases(UserInfo.getUserId(), bad);
                System.assert(false, 'Expected AuraHandledException for ' + bad);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains(bad), e.getMessage());
            }
        }
    }

    // ── CaseRow field tests ────────────────────────────────────────────────────

    @isTest
    static void caseRowHasAllRequiredFields() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltFields');
        insert u;
        insert makeCase('Field Check', 'S2', 'First Response', 'In Progress', u.Id);

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id, null);
        Test.stopTest();

        System.assertEquals(1, result.cases.size());
        System.assertEquals(1, result.totalCaseCount);
        System.assertEquals(false, result.isTruncated);
        System.assertEquals(60, result.redThresholdMinutes);
        System.assertEquals(40, result.amberThresholdPercent);
        SLTDashboardController.CaseRow row = result.cases[0];

        System.assertNotEquals(null, row.caseId,    'caseId must be set');
        System.assertNotEquals(null, row.caseNumber, 'caseNumber must be set');
        System.assertNotEquals(null, row.subject,    'subject must be set');
        System.assertNotEquals(null, row.ownerName,  'ownerName must be set');
        System.assertNotEquals(null, row.status,     'status must be set');
        System.assertEquals('S2',             row.severity);
        System.assertEquals('First Response', row.milestoneName);
        System.assertEquals('S2 label',       row.severityLabel);
        System.assertEquals('#123456',        row.severityColor);
        System.assertEquals(1,                row.severitySortOrder);
        System.assertEquals(2.00,             row.sltTargetHours);
        System.assertEquals('Green',          row.ragStatus);
        System.assertEquals('Rule',           row.source);
        System.assertEquals(false,            row.ruleMissing);
        System.assertEquals(false,            row.usesBusinessHours);
        System.assertEquals(false,            row.isViolated);
        System.assertEquals(null,             row.targetDate, 'no milestone → no target date');
        System.assertNotEquals(null,          row.deadline);
        System.assert(row.timeRemainingMins > 119 && row.timeRemainingMins <= 120,
            'S2 first response window is 120 min: ' + row.timeRemainingMins);
    }

    @isTest
    static void breachedCaseIsRedAndViolated() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltBreach');
        insert u;
        Case c = makeCase('Breached', 'S1', 'First Response', 'New', u.Id);
        insert c;
        Test.setCreatedDate(c.Id, DateTime.now().addHours(-2));

        SLTDashboardController.CaseRow row =
            SLTDashboardController.getActiveCases(u.Id, null).cases[0];

        System.assertEquals('Red', row.ragStatus);
        System.assertEquals(true,  row.isViolated);
        System.assert(row.hoursRemaining < 0);
    }

    @isTest
    static void milestoneNameShowsEnginePhaseWithoutMilestone() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltPhase');
        insert u;
        insert new List<Case>{
            makeCase('FR Case',  'S1', 'First Response', 'New', u.Id),
            new Case(Subject = 'Upd Case', Severity__c = 'S1', Status = 'New', OwnerId = u.Id,
                     First_Response_Date__c = DateTime.now(), Last_Update_Date__c = DateTime.now())
        };

        Map<String, String> phaseBySubject = new Map<String, String>();
        for (SLTDashboardController.CaseRow row : SLTDashboardController.getActiveCases(u.Id, null).cases) {
            phaseBySubject.put(row.subject, row.milestoneName);
        }
        System.assertEquals('First Response', phaseBySubject.get('FR Case'));
        System.assertEquals('Update',         phaseBySubject.get('Upd Case'));
    }

    @isTest
    static void severityResolvedFromPriorityWhenBlank() {
        // Map High → S2 so the result can only come from the engine, not the create Flow
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(),
            new List<SLT_Priority_Map__mdt>{ SLTTestFactory.priorityMap('High', 'S2', true) },
            SLTTestFactory.setting(true, 1000));
        User u = makeUser('sltPrio');
        insert u;
        Case c = new Case(Subject = 'Prio', Priority = 'High', Status = 'New', OwnerId = u.Id);
        insert c;
        update new Case(Id = c.Id, Severity__c = null);

        SLTDashboardController.CaseRow row =
            SLTDashboardController.getActiveCases(u.Id, null).cases[0];
        System.assertEquals('S2', row.severity);
        System.assertEquals(2.00, row.sltTargetHours);
    }

    // ── Ordering and limits ────────────────────────────────────────────────────

    @isTest
    static void casesOrderedMostUrgentFirst() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltOrder');
        insert u;

        Case breached = makeCase('Breached S3', 'S3', 'First Response', 'New', u.Id);
        insert new List<Case>{
            makeCase('Case S3', 'S3', 'First Response', 'New', u.Id),
            makeCase('Case S1', 'S1', 'First Response', 'New', u.Id),
            makeCase('Case S2', 'S2', 'First Response', 'New', u.Id),
            breached
        };
        Test.setCreatedDate(breached.Id, DateTime.now().addDays(-2));

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id, null);
        Test.stopTest();

        System.assertEquals(
            new List<String>{ 'Breached S3', 'Case S1', 'Case S2', 'Case S3' },
            subjects(result));
        Decimal prev = null;
        for (SLTDashboardController.CaseRow row : result.cases) {
            if (prev != null) {
                System.assert(row.hoursRemaining >= prev,
                    'Cases must be ordered ASC by hoursRemaining');
            }
            prev = row.hoursRemaining;
        }
    }

    @isTest
    static void maxRowsKeepsMostUrgentCases() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(), SLTTestFactory.defaultPriorityMaps(),
                                 SLTTestFactory.setting(true, 2));
        User u = makeUser('sltMax');
        insert u;
        insert new List<Case>{
            makeCase('Case S3', 'S3', 'First Response', 'New', u.Id),
            makeCase('Case S1', 'S1', 'First Response', 'New', u.Id),
            makeCase('Case S2', 'S2', 'First Response', 'New', u.Id)
        };

        System.assertEquals(new List<String>{ 'Case S1', 'Case S2' },
            subjects(SLTDashboardController.getActiveCases(u.Id, null)));
    }

    @isTest
    static void rowsWithoutRuleSortLastWithNoRag() {
        List<SLT_Rule__mdt> rules = new List<SLT_Rule__mdt>();
        for (SLT_Rule__mdt r : SLTTestFactory.defaultRules()) {
            if (r.Severity__c != 'S1') rules.add(r);
        }
        SLTRuleService.setConfig(rules, SLTTestFactory.defaultPriorityMaps(), SLTTestFactory.setting(true, 1000));
        User u = makeUser('sltNoRule');
        insert u;
        insert new List<Case>{
            makeCase('No Rule S1', 'S1', 'First Response', 'New', u.Id),
            makeCase('Case S3',    'S3', 'First Response', 'New', u.Id)
        };

        SLTDashboardController.DashboardResult result = SLTDashboardController.getActiveCases(u.Id, null);
        System.assertEquals(new List<String>{ 'Case S3', 'No Rule S1' }, subjects(result));
        SLTDashboardController.CaseRow missing = result.cases[1];
        System.assertEquals(true,  missing.ruleMissing);
        System.assertEquals(null,  missing.ragStatus);
        System.assertEquals(null,  missing.timeRemainingMins);
        System.assertEquals(false, missing.isViolated);
    }

    private static void useBusinessHoursConfig(Integer maxRows) {
        List<SLT_Rule__mdt> rules = SLTTestFactory.defaultRules();
        for (SLT_Rule__mdt r : rules) {
            r.Use_Business_Hours__c = true;
        }
        SLTRuleService.setConfig(rules, SLTTestFactory.defaultPriorityMaps(), SLTTestFactory.setting(true, maxRows));
    }

    // End to end with as many real cases as one test transaction can insert
    @isTest
    static void businessHoursEndToEndStaysWithinCpuLimit() {
        useBusinessHoursConfig(1000);
        User u = makeUser('sltBulk');
        insert u;

        List<Case> cases = new List<Case>();
        List<String> severities = new List<String>{ 'S1', 'S2', 'S3' };
        for (Integer i = 0; i < 1500; i++) {
            cases.add(makeCase('Bulk ' + i, severities[Math.mod(i, 3)], 'First Response', 'New', u.Id));
        }
        insert cases;

        Test.startTest();
        SLTDashboardController.DashboardResult result = SLTDashboardController.getActiveCases(u.Id, null);
        Integer cpuUsed = Limits.getCpuTime();
        Test.stopTest();

        System.debug(LoggingLevel.WARN, 'SLT_CPU_BENCH getActiveCases cases='
            + cases.size() + ' cpuMs=' + cpuUsed + ' heap=' + Limits.getHeapSize());
        System.assertEquals(1000,  result.cases.size(), 'Max_Rows__c caps the returned rows');
        System.assertEquals(1500,  result.totalCaseCount);
        System.assertEquals(false, result.isTruncated);
        System.assertEquals(true,  result.cases[0].usesBusinessHours);
        System.assert(cpuUsed < Limits.getLimitCpuTime() * 3 / 4,
            'getActiveCases used ' + cpuUsed + ' ms CPU');
    }

    // Full QUERY_ROW_CAP scale in memory (a test cannot insert 10,000 cases):
    // stage 1 estimates + ranking, stage 2 exact business-hours evaluation.
    @isTest
    static void fullScaleTwoStageRankingStaysWithinCpuLimit() {
        useBusinessHoursConfig(1000);
        DateTime now = DateTime.now();
        Map<Id, SLTRuleService.CaseInput> inputs = new Map<Id, SLTRuleService.CaseInput>();
        List<String> severities = new List<String>{ 'S1', 'S2', 'S3' };
        for (Integer i = 0; i < SLTDashboardController.QUERY_ROW_CAP; i++) {
            SLTRuleService.CaseInput input = new SLTRuleService.CaseInput();
            input.severity    = severities[Math.mod(i, 3)];
            input.createdDate = now.addMinutes(-Math.mod(i * 37, 4000));
            inputs.put(Id.valueOf('500' + String.valueOf(i).leftPad(12, '0')), input);
        }

        Test.startTest();
        Integer cpuBefore = Limits.getCpuTime();
        List<SLTDashboardController.Candidate> ranked = new List<SLTDashboardController.Candidate>();
        for (Id caseId : inputs.keySet()) {
            ranked.add(new SLTDashboardController.Candidate(caseId,
                SLTRuleService.estimate(inputs.get(caseId), now).remainingMinutes));
        }
        Integer cpuStage1 = Limits.getCpuTime() - cpuBefore;
        Set<Id> top = SLTDashboardController.topCandidates(ranked,
            1000 + SLTDashboardController.CANDIDATE_MARGIN);
        Integer cpuSort = Limits.getCpuTime() - cpuBefore - cpuStage1;
        for (Id caseId : top) {
            SLTRuleService.evaluate(inputs.get(caseId), now);
        }
        Integer cpuUsed = Limits.getCpuTime() - cpuBefore;
        Test.stopTest();

        System.debug(LoggingLevel.WARN, 'SLT_CPU_BENCH two-stage cases=' + inputs.size()
            + ' candidates=' + top.size() + ' stage1Ms=' + cpuStage1 + ' sortMs=' + cpuSort
            + ' totalMs=' + cpuUsed + ' heap=' + Limits.getHeapSize());
        System.assertEquals(1250, top.size());
        System.assert(cpuUsed < Limits.getLimitCpuTime() * 3 / 4,
            'Two-stage ranking at full scale used ' + cpuUsed + ' ms CPU');
    }

    @isTest
    static void topCandidatesRankMostUrgentFirstAndNullsLast() {
        Id a = '500000000000001';
        Id b = '500000000000002';
        Id c = '500000000000003';
        Set<Id> top = SLTDashboardController.topCandidates(new List<SLTDashboardController.Candidate>{
            new SLTDashboardController.Candidate(a, null),
            new SLTDashboardController.Candidate(b, 500),
            new SLTDashboardController.Candidate(c, -20)
        }, 2);
        System.assertEquals(new Set<Id>{ b, c }, top);
    }

    @isTest
    static void topCandidatesHandlesTiesAndFillsWithNulls() {
        Id a = '500000000000001';
        Id b = '500000000000002';
        Id c = '500000000000003';
        Id d = '500000000000004';
        List<SLTDashboardController.Candidate> ranked = new List<SLTDashboardController.Candidate>{
            new SLTDashboardController.Candidate(a, 10),
            new SLTDashboardController.Candidate(b, 10),
            new SLTDashboardController.Candidate(c, 5),
            new SLTDashboardController.Candidate(d, null)
        };
        Set<Id> two = SLTDashboardController.topCandidates(ranked, 2);
        System.assertEquals(2, two.size());
        System.assert(two.contains(c), 'most urgent always included');

        System.assertEquals(new Set<Id>{ a, b, c, d }, SLTDashboardController.topCandidates(ranked, 4));
        System.assertEquals(new Set<Id>{ a, b, c }, SLTDashboardController.topCandidates(ranked, 3));
    }

    @isTest
    static void newUrgentCaseNotDroppedBehindOlderCases() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(), SLTTestFactory.defaultPriorityMaps(),
                                 SLTTestFactory.setting(true, 1));
        SLTDashboardController.CANDIDATE_MARGIN = 0;
        User u = makeUser('sltNewS1');
        insert u;

        List<Case> older = new List<Case>();
        for (Integer i = 0; i < 3; i++) {
            older.add(makeCase('Old S3 ' + i, 'S3', 'First Response', 'New', u.Id));
        }
        insert older;
        for (Case c : older) {
            Test.setCreatedDate(c.Id, DateTime.now().addHours(-10));
        }
        insert makeCase('New S1', 'S1', 'First Response', 'New', u.Id);

        SLTDashboardController.DashboardResult result = SLTDashboardController.getActiveCases(u.Id, null);
        System.assertEquals(new List<String>{ 'New S1' }, subjects(result));
        System.assertEquals(4, result.totalCaseCount);
        System.assertEquals(false, result.isTruncated);
    }

    @isTest
    static void hittingQueryCapSetsTruncatedFlag() {
        SLTTestFactory.useDefaultConfig();
        SLTDashboardController.QUERY_ROW_CAP = 2;
        User u = makeUser('sltTrunc');
        insert u;
        insert new List<Case>{
            makeCase('Case A', 'S1', 'First Response', 'New', u.Id),
            makeCase('Case B', 'S2', 'First Response', 'New', u.Id),
            makeCase('Case C', 'S3', 'First Response', 'New', u.Id)
        };

        SLTDashboardController.DashboardResult result = SLTDashboardController.getActiveCases(u.Id, null);
        System.assertEquals(true, result.isTruncated);
        System.assertEquals(2,    result.totalCaseCount);
        System.assertEquals(2,    result.cases.size());
    }

    @isTest
    static void noActiveCasesReturnsEmptyList() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltEmpty');
        insert u;

        Test.startTest();
        SLTDashboardController.DashboardResult result =
            SLTDashboardController.getActiveCases(u.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(0, result.cases.size());
    }

    @isTest
    static void milestoneModeOffSkipsMilestones() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(), SLTTestFactory.defaultPriorityMaps(),
                                 SLTTestFactory.setting(false, 1000));
        User u = makeUser('sltMsOff');
        insert u;
        insert makeCase('Rule Only', 'S1', 'First Response', 'New', u.Id);

        SLTDashboardController.CaseRow row =
            SLTDashboardController.getActiveCases(u.Id, null).cases[0];
        System.assertEquals('Rule', row.source);
    }

    // ── Milestone mapping ──────────────────────────────────────────────────────

    // CaseMilestone cannot be inserted without an Entitlement Process, so build
    // in-memory records via JSON (keeps the test free of a static CaseMilestone reference).
    private static SObject fakeMilestone(Id caseId, String name, DateTime startDate, DateTime targetDate) {
        Map<String, Object> rec = new Map<String, Object>{
            'attributes'     => new Map<String, Object>{ 'type' => 'CaseMilestone' },
            'CaseId'         => caseId,
            'StartDate'      => startDate,
            'TargetDate'     => targetDate,
            'CompletionDate' => null,
            'IsCompleted'    => false,
            'IsViolated'     => false,
            'MilestoneType'  => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'MilestoneType' },
                'Name'       => name
            }
        };
        return (SObject) JSON.deserialize(JSON.serialize(rec), Type.forName('Schema.CaseMilestone'));
    }

    @isTest
    static void mapMilestonesKeepsEarliestPerCase() {
        if (!Schema.getGlobalDescribe().containsKey('CaseMilestone')) return;
        Id caseA = '500000000000001';
        Id caseB = '500000000000002';
        DateTime now = DateTime.now();

        Map<Id, SLTRuleService.MilestoneInfo> byCase = SLTDashboardController.mapMilestones(
            new List<SObject>{
                fakeMilestone(caseA, 'First Response', now.addHours(-1), now.addHours(1)),
                fakeMilestone(caseA, 'Resolution',     now.addHours(-1), now.addHours(9)),
                fakeMilestone(caseB, 'Update',         now.addHours(-2), now.addHours(2))
            });

        System.assertEquals(2, byCase.size());
        SLTRuleService.MilestoneInfo a = byCase.get(caseA);
        System.assertEquals('First Response', a.name);
        System.assertEquals(now.addHours(1),  a.targetDate);
        System.assertEquals(now.addHours(-1), a.startDate);
        System.assertEquals(false, a.isCompleted);
        System.assertEquals(false, a.isViolated);
        System.assertEquals('Update', byCase.get(caseB).name);
    }

    // ── Permission-based scope tests ───────────────────────────────────────────

    @isTest
    static void noScopePermissionDefaultsToOwnCases() {
        SLTTestFactory.useDefaultConfig();
        User u = makeUser('sltNoScope');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            grantDashboardAccess(new List<User>{ u });
        }
        insert makeCase('Own Case', 'S2', 'First Response', 'New', u.Id);

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(u) {
            result = SLTDashboardController.getActiveCases(null, null);
        }
        Test.stopTest();

        System.assertEquals('Your Cases', result.scopeLabel);
        System.assertEquals(1, result.cases.size());
    }

    @isTest
    static void scopeOwnShowsOnlyUsersCases() {
        SLTTestFactory.useDefaultConfig();
        List<UserRole> roles;
        User agent1;
        User agent2;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles  = makeTwoLevelRoles();
            agent1 = makeUserWithRole('sltAgt1', roles[1].Id);
            agent2 = makeUserWithRole('sltAgt2', roles[1].Id);
            insert new List<User>{ agent1, agent2 };
            grantDashboardAccess(new List<User>{ agent1 });
            assignPermissionSet(agent1.Id, 'SLTScope_Own');
        }

        insert new List<Case>{
            makeCase('Agent1 Case', 'S1', 'First Response', 'New', agent1.Id),
            makeCase('Agent2 Case', 'S2', 'Update',         'New', agent2.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(agent1) {
            result = SLTDashboardController.getActiveCases(null, null);
        }
        Test.stopTest();

        System.assertEquals('Your Cases', result.scopeLabel);
        System.assertEquals(1, result.cases.size());
        System.assertEquals('Agent1 Case', result.cases[0].subject);
    }

    @isTest
    static void scopeTeamShowsDirectSubroleUsers() {
        SLTTestFactory.useDefaultConfig();
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
            grantDashboardAccess(new List<User>{ tl });
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
            result = SLTDashboardController.getActiveCases(null, null);
        }
        Test.stopTest();

        System.assertEquals('Your Team', result.scopeLabel);
        System.assertEquals(3, result.cases.size(),
            'TL should see own case + both agent cases');
    }

    @isTest
    static void scopeOrgShowsEntireSubtree() {
        SLTTestFactory.useDefaultConfig();
        List<UserRole> roles;
        User manager;
        User agent;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles   = makeTwoLevelRoles();
            manager = makeUserWithRole('sltMgr',  roles[0].Id);
            agent   = makeUserWithRole('sltAgt5', roles[1].Id);
            insert new List<User>{ manager, agent };
            grantDashboardAccess(new List<User>{ manager });
            assignPermissionSet(manager.Id, 'SLTScope_Org');
        }

        insert new List<Case>{
            makeCase('Manager Case', 'S1', 'First Response', 'New', manager.Id),
            makeCase('Agent5 Case',  'S2', 'Update',         'New', agent.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(manager) {
            result = SLTDashboardController.getActiveCases(null, null);
        }
        Test.stopTest();

        System.assertEquals('Your Organisation', result.scopeLabel);
        System.assertEquals(2, result.cases.size(),
            'Manager should see own case + agent case');
    }

    @isTest
    static void scopeAllShowsEveryCase() {
        SLTTestFactory.useDefaultConfig();
        List<UserRole> roles;
        User director;
        User agent;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            roles    = makeTwoLevelRoles();
            director = makeUserWithRole('sltDir',  roles[0].Id);
            agent    = makeUserWithRole('sltAgt6', roles[1].Id);
            insert new List<User>{ director, agent };
            grantDashboardAccess(new List<User>{ director });
            assignPermissionSet(director.Id, 'SLTScope_All');
        }

        insert new List<Case>{
            makeCase('Director Case', 'S1', 'First Response', 'New', director.Id),
            makeCase('Agent6 Case',   'S3', 'Update',         'New', agent.Id)
        };

        SLTDashboardController.DashboardResult result;
        Test.startTest();
        System.runAs(director) {
            result = SLTDashboardController.getActiveCases(null, 'ignored-for-all-scope');
        }
        Test.stopTest();

        System.assertEquals('All Cases', result.scopeLabel);
        System.assert(result.cases.size() >= 2,
            'Director should see all open cases in the org');
    }
}
