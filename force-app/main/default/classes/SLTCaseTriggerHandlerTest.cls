@isTest
private class SLTCaseTriggerHandlerTest {

    @isTest
    static void blankSeverityMappedFromPriority() {
        SLTTestFactory.useDefaultConfig();
        List<Case> cases = new List<Case>{
            new Case(Priority = 'High'),
            new Case(Priority = 'Medium'),
            new Case(Priority = 'Low'),
            new Case(Priority = null)
        };
        SLTCaseTriggerHandler.applyDefaultSeverity(cases);

        System.assertEquals('S1', cases[0].Severity__c);
        System.assertEquals('S2', cases[1].Severity__c);
        System.assertEquals('S3', cases[2].Severity__c);
        System.assertEquals('S3', cases[3].Severity__c, 'blank Priority → default mapping');
    }

    @isTest
    static void manualSeverityIsKept() {
        SLTTestFactory.useDefaultConfig();
        List<Case> cases = new List<Case>{ new Case(Priority = 'High', Severity__c = 'S3') };
        SLTCaseTriggerHandler.applyDefaultSeverity(cases);
        System.assertEquals('S3', cases[0].Severity__c);
    }

    @isTest
    static void severityMissingFromPicklistIsNotWritten() {
        SLTRuleService.setConfig(SLTTestFactory.defaultRules(),
            new List<SLT_Priority_Map__mdt>{ SLTTestFactory.priorityMap('High', 'P1', true) },
            SLTTestFactory.setting(true, 1000));
        List<Case> cases = new List<Case>{ new Case(Priority = 'High') };
        SLTCaseTriggerHandler.applyDefaultSeverity(cases);
        System.assertEquals(null, cases[0].Severity__c);
    }

    @isTest
    static void insertedCaseGetsSeverity() {
        SLTTestFactory.useDefaultConfig();
        Case c = new Case(Subject = 'Trigger check', Status = 'New', Priority = 'Medium');
        insert c;
        System.assertEquals('S2', [SELECT Severity__c FROM Case WHERE Id = :c.Id].Severity__c);
    }
}
