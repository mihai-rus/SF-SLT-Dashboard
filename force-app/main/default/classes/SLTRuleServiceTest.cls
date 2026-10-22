@isTest
private class SLTRuleServiceTest {

    // Fixed clock so every assertion is exact
    private static final DateTime NOW = DateTime.newInstanceGmt(2026, 1, 7, 12, 0, 0);

    // ── Helpers ────────────────────────────────────────────────────────────────

    private static SLTRuleService.CaseInput input(String severity, String priority,
                                                  DateTime created, DateTime firstResponse,
                                                  DateTime lastUpdate) {
        SLTRuleService.CaseInput i = new SLTRuleService.CaseInput();
        i.severity          = severity;
        i.priority          = priority;
        i.createdDate       = created;
        i.firstResponseDate = firstResponse;
        i.lastUpdateDate    = lastUpdate;
        return i;
    }

    // First Response phase case created so that exactly `remaining` minutes are left
    private static SLTRuleService.CaseInput firstResponseWithRemaining(String severity,
                                                                       Integer target,
                                                                       Integer remaining) {
        return input(severity, null, NOW.addMinutes(remaining - target), null, null);
    }

    private static SLTRuleService.MilestoneInfo milestone(DateTime startDate, DateTime targetDate) {
        SLTRuleService.MilestoneInfo m = new SLTRuleService.MilestoneInfo();
        m.name       = 'Entitlement Milestone';
        m.startDate  = startDate;
        m.targetDate = targetDate;
        return m;
    }

    private static List<SLT_Rule__mdt> businessHoursRules(String businessHoursName) {
        SLT_Rule__mdt r = SLTTestFactory.rule('S1', SLTRuleService.PHASE_FIRST_RESPONSE, 120);
        r.Use_Business_Hours__c  = true;
        r.Business_Hours_Name__c = businessHoursName;
        return new List<SLT_Rule__mdt>{ r };
    }

    private static BusinessHours defaultBusinessHours() {
        return [SELECT Id, Name FROM BusinessHours WHERE IsDefault = true LIMIT 1];
    }

    private static User makeStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName         = 'SLT',
            LastName          = 'Engine',
            Email             = 'sltEngine@slt-test.example.com',
            Username          = 'sltEngine@slt-test.example.com',
            Alias             = 'sltEng',
            TimeZoneSidKey    = 'America/New_York',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );
        insert u;
        return u;
    }

    // ── Severity × phase ───────────────────────────────────────────────────────

    @isTest
    static void eachSeverityAndPhaseUsesItsRuleTarget() {
        SLTTestFactory.useDefaultConfig();
        Map<String, Integer> expected = new Map<String, Integer>{
            'S1|First Response' => 30,   'S1|Update' => 240,
            'S2|First Response' => 120,  'S2|Update' => 1440,
            'S3|First Response' => 1440, 'S3|Update' => 2160
        };
        DateTime tenMinutesAgo = NOW.addMinutes(-10);

        for (String key : expected.keySet()) {
            String  severity = key.substringBefore('|');
            Boolean isUpdate = key.endsWith(SLTRuleService.PHASE_UPDATE);
            SLTRuleService.Result r = SLTRuleService.evaluate(isUpdate
                ? input(severity, null, NOW.addDays(-3), tenMinutesAgo, tenMinutesAgo)
                : input(severity, null, tenMinutesAgo, null, null), NOW);

            Integer target = expected.get(key);
            System.assertEquals(key.substringAfter('|'), r.phase, key);
            System.assertEquals(SLTRuleService.SOURCE_RULE, r.source, key);
            System.assertEquals(false, r.ruleMissing, key);
            System.assertEquals(false, r.usesBusinessHours, key);
            System.assertEquals(target, r.targetMinutes, key);
            System.assertEquals(10, r.elapsedMinutes, key);
            System.assertEquals(target - 10, r.remainingMinutes, key);
            System.assertEquals(tenMinutesAgo, r.startTime, key);
            System.assertEquals(tenMinutesAgo.addMinutes(target), r.deadline, key);
        }
    }

    // ── Phase and clock start ──────────────────────────────────────────────────

    @isTest
    static void firstResponsePhaseStartsAtCreatedDate() {
        SLTTestFactory.useDefaultConfig();
        DateTime created = NOW.addMinutes(-5);
        SLTRuleService.Result r = SLTRuleService.evaluate(input('S2', null, created, null, null), NOW);
        System.assertEquals(SLTRuleService.PHASE_FIRST_RESPONSE, r.phase);
        System.assertEquals(created, r.startTime);
    }

    @isTest
    static void updatePhaseStartsAtFirstResponseWhenLastUpdateBlank() {
        SLTTestFactory.useDefaultConfig();
        DateTime firstResponse = NOW.addHours(-2);
        SLTRuleService.Result r = SLTRuleService.evaluate(
            input('S2', null, NOW.addDays(-1), firstResponse, null), NOW);
        System.assertEquals(SLTRuleService.PHASE_UPDATE, r.phase);
        System.assertEquals(firstResponse, r.startTime);
        System.assertEquals(120, r.elapsedMinutes);
    }

    @isTest
    static void updatePhaseStartsAtLastUpdateWhenLater() {
        SLTTestFactory.useDefaultConfig();
        DateTime lastUpdate = NOW.addMinutes(-15);
        SLTRuleService.Result r = SLTRuleService.evaluate(
            input('S1', null, NOW.addDays(-1), NOW.addHours(-5), lastUpdate), NOW);
        System.assertEquals(SLTRuleService.PHASE_UPDATE, r.phase);
        System.assertEquals(lastUpdate, r.startTime);
        System.assertEquals(225, r.remainingMinutes);
    }

    // ── Business hours ─────────────────────────────────────────────────────────

    @isTest
    static void businessHoursUseOrgDefaultWhenNameBlank() {
        BusinessHours bh = defaultBusinessHours();
        SLTRuleService.setConfig(businessHoursRules(null), SLTTestFactory.defaultPriorityMaps(),
                                 SLTTestFactory.setting(false, 1000));
        DateTime created = NOW.addHours(-3);
        User u = makeStandardUser();

        SLTRuleService.Result r;
        System.runAs(u) {   // BusinessHours must be readable in user mode
            r = SLTRuleService.evaluate(input('S1', null, created, null, null), NOW);
        }

        Decimal expectedElapsed = BusinessHours.diff(bh.Id, created, NOW) / (Decimal) 60000;
        System.assertEquals(true, r.usesBusinessHours);
        System.assertEquals(BusinessHours.add(bh.Id, created, 120 * 60000L), r.deadline);
        System.assertEquals(expectedElapsed, r.elapsedMinutes);
        System.assertEquals(120 - expectedElapsed, r.remainingMinutes);
    }

    @isTest
    static void businessHoursResolvedByNameAndUnknownNameFallsBack() {
        BusinessHours bh = defaultBusinessHours();
        DateTime created = NOW.addHours(-1);
        DateTime expectedDeadline = BusinessHours.add(bh.Id, created, 120 * 60000L);

        SLTRuleService.setConfig(businessHoursRules(bh.Name), null, null);
        System.assertEquals(expectedDeadline,
            SLTRuleService.evaluate(input('S1', null, created, null, null), NOW).deadline);

        SLTRuleService.setConfig(businessHoursRules('No Such Business Hours'), null, null);
        SLTRuleService.Result r = SLTRuleService.evaluate(input('S1', null, created, null, null), NOW);
        System.assertEquals(true, r.usesBusinessHours);
        System.assertEquals(expectedDeadline, r.deadline);
    }

    @isTest
    static void estimateSkipsBusinessHoursAndIsLowerBound() {
        SLTRuleService.setConfig(businessHoursRules(null), null, null);
        SLTRuleService.CaseInput i = input('S1', null, NOW.addHours(-20), null, null);

        SLTRuleService.Result exact    = SLTRuleService.evaluate(i, NOW);
        SLTRuleService.Result estimate = SLTRuleService.estimate(i, NOW);

        System.assertEquals(true,  exact.usesBusinessHours);
        System.assertEquals(false, estimate.usesBusinessHours);
        System.assertEquals(NOW.addHours(-20).addMinutes(120), estimate.deadline);
        System.assert(estimate.remainingMinutes <= exact.remainingMinutes,
            'Calendar estimate must never report more time left than business hours');
    }

    @isTest
    static void businessHoursExactEvaluationAtCapStaysWithinCpuLimit() {
        SLTRuleService.setConfig(businessHoursRules(null), null, null);
        List<SLTRuleService.CaseInput> inputs = new List<SLTRuleService.CaseInput>();
        for (Integer i = 0; i < SLTDashboardController.EXACT_ROW_CAP; i++) {
            inputs.add(input('S1', null, NOW.addMinutes(-Math.mod(i * 37, 20000)), null, null));
        }

        Test.startTest();
        Integer cpuBefore = Limits.getCpuTime();
        for (SLTRuleService.CaseInput i : inputs) {
            SLTRuleService.evaluate(i, NOW);
        }
        Integer cpuUsed = Limits.getCpuTime() - cpuBefore;
        Test.stopTest();

        System.debug(LoggingLevel.WARN, 'SLT_CPU_BENCH exact business-hours evaluations='
            + inputs.size() + ' cpuMs=' + cpuUsed);
        System.assert(cpuUsed < Limits.getLimitCpuTime() / 2,
            'Exact evaluation of EXACT_ROW_CAP cases must use under half the CPU limit, used ' + cpuUsed + ' ms');
    }

    // ── Milestone mode ─────────────────────────────────────────────────────────

    @isTest
    static void milestoneModeUsesMilestoneWindow() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.CaseInput i = input('S1', null, NOW.addHours(-8), null, null);
        i.milestone = milestone(NOW.addMinutes(-30), NOW.addMinutes(90));

        SLTRuleService.Result r = SLTRuleService.evaluate(i, NOW);

        System.assertEquals(SLTRuleService.SOURCE_MILESTONE, r.source);
        System.assertEquals(120, r.targetMinutes);
        System.assertEquals(30,  r.elapsedMinutes);
        System.assertEquals(90,  r.remainingMinutes);
        System.assertEquals(NOW.addMinutes(90), r.deadline);
        // Rule alone would say breached (S1 first response = 30 min, 8 h elapsed);
        // RAG must follow the milestone window instead.
        System.assertEquals(SLTRuleService.RAG_GREEN, r.ragStatus);
        System.assertEquals(false, r.isBreached);
    }

    @isTest
    static void milestoneModeRagUsesSameThresholds() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.CaseInput i = input('S1', null, NOW, null, null);

        i.milestone = milestone(NOW.addMinutes(-600), NOW.addMinutes(100));   // 100 < 40% of 700
        System.assertEquals(SLTRuleService.RAG_AMBER, SLTRuleService.evaluate(i, NOW).ragStatus);

        i.milestone = milestone(NOW.addMinutes(-10), NOW.addMinutes(50));     // < 60 min
        System.assertEquals(SLTRuleService.RAG_RED, SLTRuleService.evaluate(i, NOW).ragStatus);

        i.milestone = milestone(NOW.addMinutes(-60), NOW.addMinutes(-1));     // breached
        SLTRuleService.Result r = SLTRuleService.evaluate(i, NOW);
        System.assertEquals(SLTRuleService.RAG_RED, r.ragStatus);
        System.assertEquals(true, r.isBreached);
    }

    @isTest
    static void milestoneIgnoredWhenModeOff() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(), null, SLTTestFactory.setting(false, 1000));
        SLTRuleService.CaseInput i = input('S1', null, NOW.addMinutes(-10), null, null);
        i.milestone = milestone(NOW.addMinutes(-30), NOW.addMinutes(90));

        SLTRuleService.Result r = SLTRuleService.evaluate(i, NOW);
        System.assertEquals(SLTRuleService.SOURCE_RULE, r.source);
        System.assertEquals(30, r.targetMinutes);
    }

    @isTest
    static void completedMilestoneIgnored() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.CaseInput i = input('S1', null, NOW.addMinutes(-10), null, null);
        i.milestone = milestone(NOW.addMinutes(-30), NOW.addMinutes(90));
        i.milestone.isCompleted = true;

        System.assertEquals(SLTRuleService.SOURCE_RULE, SLTRuleService.evaluate(i, NOW).source);
    }

    @isTest
    static void milestoneWindowUsedEvenWithoutRule() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.CaseInput i = input('S9', null, NOW, null, null);
        i.milestone = milestone(NOW.addMinutes(-30), NOW.addMinutes(90));

        SLTRuleService.Result r = SLTRuleService.evaluate(i, NOW);
        System.assertEquals(false, r.ruleMissing);
        System.assertEquals(SLTRuleService.RAG_GREEN, r.ragStatus);
    }

    // ── Severity resolution ────────────────────────────────────────────────────

    @isTest
    static void severityResolution() {
        SLTTestFactory.useDefaultConfig();
        System.assertEquals('S2', SLTRuleService.resolveSeverity('S2', 'High'),   'manual Severity wins');
        System.assertEquals('S1', SLTRuleService.resolveSeverity(null, 'High'),   'mapped Priority');
        System.assertEquals('S2', SLTRuleService.resolveSeverity('',   'Medium'), 'mapped Priority');
        System.assertEquals('S3', SLTRuleService.resolveSeverity(null, 'Urgent'), 'unmapped → default');
        System.assertEquals('S3', SLTRuleService.resolveSeverity(null, null),     'blank → default');
    }

    @isTest
    static void unmappedPriorityWithoutDefaultIsRuleMissing() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(),
            new List<SLT_Priority_Map__mdt>{ SLTTestFactory.priorityMap('High', 'S1', false) },
            SLTTestFactory.setting(true, 1000));

        SLTRuleService.Result r = SLTRuleService.evaluate(input(null, 'Urgent', NOW, null, null), NOW);
        System.assertEquals(null, r.severity);
        System.assertEquals(true, r.ruleMissing);
        System.assertEquals(null, r.ragStatus);
    }

    // ── Missing / inactive rules ───────────────────────────────────────────────

    @isTest
    static void missingRuleReturnsNullRagNotRed() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.Result r = SLTRuleService.evaluate(input('S9', null, NOW.addDays(-5), null, null), NOW);

        System.assertEquals(true,  r.ruleMissing);
        System.assertEquals(null,  r.ragStatus);
        System.assertEquals(false, r.isBreached);
        System.assertEquals(null,  r.deadline);
        System.assertEquals(null,  r.remainingMinutes);
        System.assertEquals(SLTRuleService.SOURCE_RULE, r.source);
        System.assertEquals(SLTRuleService.PHASE_FIRST_RESPONSE, r.phase);
    }

    @isTest
    static void inactiveRuleIsIgnored() {
        List<SLT_Rule__mdt> rules = SLTTestFactory.defaultRules();
        for (SLT_Rule__mdt r : rules) {
            if (r.Severity__c == 'S1') r.Active__c = false;
        }
        SLTRuleService.setConfig(rules, SLTTestFactory.defaultPriorityMaps(), SLTTestFactory.setting(true, 1000));

        SLTRuleService.Result r = SLTRuleService.evaluate(input('S1', null, NOW, null, null), NOW);
        System.assertEquals(true, r.ruleMissing);
        System.assertEquals(null, r.severityLabel, 'inactive rules supply no display values');
    }

    @isTest
    static void missingStartTimeIsRuleMissing() {
        SLTTestFactory.useDefaultConfig();
        System.assertEquals(true, SLTRuleService.evaluate(input('S1', null, null, null, null), NOW).ruleMissing);
    }

    // ── RAG boundaries ─────────────────────────────────────────────────────────

    @isTest
    static void breachedIsRed() {
        SLTTestFactory.useDefaultConfig();
        SLTRuleService.Result r = SLTRuleService.evaluate(firstResponseWithRemaining('S1', 30, -1), NOW);
        System.assertEquals(SLTRuleService.RAG_RED, r.ragStatus);
        System.assertEquals(true, r.isBreached);

        r = SLTRuleService.evaluate(firstResponseWithRemaining('S1', 30, 0), NOW);
        System.assertEquals(SLTRuleService.RAG_RED, r.ragStatus, 'exactly at deadline = breached');
        System.assertEquals(true, r.isBreached);
    }

    @isTest
    static void redThresholdBoundary() {
        SLTTestFactory.useDefaultConfig();
        // S3 first response = 1440 min; Amber band starts below 576 min
        System.assertEquals(SLTRuleService.RAG_AMBER,
            SLTRuleService.evaluate(firstResponseWithRemaining('S3', 1440, 60), NOW).ragStatus);
        SLTRuleService.Result r = SLTRuleService.evaluate(firstResponseWithRemaining('S3', 1440, 59), NOW);
        System.assertEquals(SLTRuleService.RAG_RED, r.ragStatus);
        System.assertEquals(false, r.isBreached);
    }

    @isTest
    static void amberThresholdBoundary() {
        SLTTestFactory.useDefaultConfig();
        System.assertEquals(SLTRuleService.RAG_GREEN,
            SLTRuleService.evaluate(firstResponseWithRemaining('S3', 1440, 576), NOW).ragStatus);
        System.assertEquals(SLTRuleService.RAG_AMBER,
            SLTRuleService.evaluate(firstResponseWithRemaining('S3', 1440, 575), NOW).ragStatus);
    }

    @isTest
    static void missingSettingOnlyBreachIsRed() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(), SLTTestFactory.defaultPriorityMaps(), null);
        System.assertEquals(SLTRuleService.RAG_GREEN,
            SLTRuleService.evaluate(firstResponseWithRemaining('S3', 1440, 1), NOW).ragStatus);
        System.assertEquals(null,  SLTRuleService.maxRows());
        System.assertEquals(false, SLTRuleService.useCaseMilestones());
        System.assertEquals(0,     SLTRuleService.redThresholdMinutes());
        System.assertEquals(0,     SLTRuleService.amberThresholdPercent());
    }

    // ── Display values and configuration loading ───────────────────────────────

    @isTest
    static void severityDisplayValuesComeFromRule() {
        SLT_Rule__mdt s1 = SLTTestFactory.rule('S1', SLTRuleService.PHASE_FIRST_RESPONSE, 30);
        s1.Severity_Label__c = 'Production Down';
        s1.Severity_Color__c = '#8E0A08';
        s1.Sort_Order__c     = 1;
        SLTRuleService.setConfig(new List<SLT_Rule__mdt>{ s1 }, null, SLTTestFactory.setting(true, 50));

        SLTRuleService.Result r = SLTRuleService.evaluate(input('S1', null, NOW, null, null), NOW);
        System.assertEquals('Production Down', r.severityLabel);
        System.assertEquals('#8E0A08',         r.severityColor);
        System.assertEquals(1,                 r.severitySortOrder);
        System.assertEquals(50,                SLTRuleService.maxRows());
        System.assertEquals(60,                SLTRuleService.redThresholdMinutes());
        System.assertEquals(40,                SLTRuleService.amberThresholdPercent());
    }

    @isTest
    static void loadsOrgConfigurationWhenNothingInjected() {
        // Must not throw whatever SLT_*__mdt records exist in the org
        SLTRuleService.maxRows();
        SLTRuleService.useCaseMilestones();
        SLTRuleService.Result r = SLTRuleService.evaluate(input(null, 'High', DateTime.now(), null, null));
        System.assertNotEquals(null, r);
        System.assertEquals(SLTRuleService.PHASE_FIRST_RESPONSE, r.phase);
    }
}
