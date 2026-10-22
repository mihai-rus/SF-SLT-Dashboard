@isTest
public class SLTTestFactory {

    // In-memory SLT configuration mirroring the shipped default records, so tests
    // never depend on which SLT_*__mdt records exist in the org.

    public static SLT_Rule__mdt rule(String severity, String phase, Decimal targetMinutes) {
        return new SLT_Rule__mdt(
            Severity__c           = severity,
            Phase__c              = phase,
            Target_Minutes__c     = targetMinutes,
            Use_Business_Hours__c = false,
            Severity_Label__c     = severity + ' label',
            Severity_Color__c     = '#123456',
            Sort_Order__c         = 1,
            Active__c             = true
        );
    }

    public static List<SLT_Rule__mdt> defaultRules() {
        return new List<SLT_Rule__mdt>{
            rule('S1', SLTRuleService.PHASE_FIRST_RESPONSE, 30),
            rule('S1', SLTRuleService.PHASE_UPDATE,         240),
            rule('S2', SLTRuleService.PHASE_FIRST_RESPONSE, 120),
            rule('S2', SLTRuleService.PHASE_UPDATE,         1440),
            rule('S3', SLTRuleService.PHASE_FIRST_RESPONSE, 1440),
            rule('S3', SLTRuleService.PHASE_UPDATE,         2160)
        };
    }

    public static SLT_Priority_Map__mdt priorityMap(String priority, String severity, Boolean isDefault) {
        return new SLT_Priority_Map__mdt(
            Priority_Value__c = priority,
            Severity__c       = severity,
            Is_Default__c     = isDefault
        );
    }

    public static List<SLT_Priority_Map__mdt> defaultPriorityMaps() {
        return new List<SLT_Priority_Map__mdt>{
            priorityMap('High',   'S1', false),
            priorityMap('Medium', 'S2', false),
            priorityMap('Low',    'S3', true)
        };
    }

    public static SLT_Setting__mdt setting(Boolean useCaseMilestones, Integer maxRows) {
        return new SLT_Setting__mdt(
            Red_Threshold_Minutes__c   = 60,
            Amber_Threshold_Percent__c = 40,
            Use_Case_Milestones__c     = useCaseMilestones,
            Max_Rows__c                = maxRows
        );
    }

    public static void useDefaultConfig() {
        SLTRuleService.setConfig(defaultRules(), defaultPriorityMaps(), setting(true, 1000));
    }
}
