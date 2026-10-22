public with sharing class SLTRuleService {

    // ── Constants (vocabulary, not business rules) ─────────────────────────────

    public static final String PHASE_FIRST_RESPONSE = 'First Response';
    public static final String PHASE_UPDATE         = 'Update';

    public static final String SOURCE_RULE          = 'Rule';
    public static final String SOURCE_MILESTONE     = 'CaseMilestone';

    public static final String RAG_RED   = 'Red';
    public static final String RAG_AMBER = 'Amber';
    public static final String RAG_GREEN = 'Green';

    private static final String  SETTING_RECORD = 'Default';
    private static final Decimal MS_PER_MINUTE  = 60000;

    // ── Public value types ─────────────────────────────────────────────────────

    // An open CaseMilestone, decoupled from the CaseMilestone SObject so the
    // engine has no compile-time dependency on Entitlement Management.
    public class MilestoneInfo {
        public String   name;
        public DateTime startDate;
        public DateTime targetDate;
        public DateTime completionDate;
        public Boolean  isViolated  = false;
        public Boolean  isCompleted = false;
    }

    public class CaseInput {
        public String        severity;
        public String        priority;
        public DateTime      createdDate;
        public DateTime      firstResponseDate;
        public DateTime      lastUpdateDate;
        public MilestoneInfo milestone;
    }

    public class Result {
        public String   severity;
        public String   severityLabel;
        public String   severityColor;
        public Decimal  severitySortOrder;
        public String   phase;
        public DateTime startTime;
        public DateTime deadline;
        public Decimal  targetMinutes;
        public Decimal  elapsedMinutes;
        public Decimal  remainingMinutes;
        public String   ragStatus;
        public Boolean  isBreached        = false;
        public String   source;
        public Boolean  ruleMissing       = false;
        public Boolean  usesBusinessHours = false;
    }

    // ── Configuration (loaded once per transaction) ────────────────────────────

    private class Config {
        Map<String, SLT_Rule__mdt> ruleByKey          = new Map<String, SLT_Rule__mdt>();
        Map<String, SLT_Rule__mdt> displayBySeverity  = new Map<String, SLT_Rule__mdt>();
        Map<String, String>        severityByPriority = new Map<String, String>();
        String  defaultSeverity;
        Decimal redThresholdMinutes   = 0;
        Decimal amberThresholdPercent = 0;
        Boolean useCaseMilestones     = false;
        Integer maxRows;
    }

    private static Config          cfg;
    private static Map<String, Id> businessHoursIdByName;
    private static Id              defaultBusinessHoursId;

    @TestVisible
    private static void setConfig(List<SLT_Rule__mdt> rules,
                                  List<SLT_Priority_Map__mdt> priorityMaps,
                                  SLT_Setting__mdt setting) {
        cfg = buildConfig(rules, priorityMaps, setting);
    }

    private static Config config() {
        if (cfg == null) {
            cfg = buildConfig(
                SLT_Rule__mdt.getAll().values(),
                SLT_Priority_Map__mdt.getAll().values(),
                SLT_Setting__mdt.getInstance(SETTING_RECORD)
            );
        }
        return cfg;
    }

    private static Config buildConfig(List<SLT_Rule__mdt> rules,
                                      List<SLT_Priority_Map__mdt> priorityMaps,
                                      SLT_Setting__mdt setting) {
        Config c = new Config();

        for (SLT_Rule__mdt r : rules == null ? new List<SLT_Rule__mdt>() : rules) {
            if (r.Active__c != true || String.isBlank(r.Severity__c)) continue;
            String key = ruleKey(r.Severity__c, r.Phase__c);
            if (!c.ruleByKey.containsKey(key)) c.ruleByKey.put(key, r);
            if (!c.displayBySeverity.containsKey(r.Severity__c)) c.displayBySeverity.put(r.Severity__c, r);
        }

        for (SLT_Priority_Map__mdt m : priorityMaps == null ? new List<SLT_Priority_Map__mdt>() : priorityMaps) {
            if (String.isBlank(m.Severity__c)) continue;
            if (String.isNotBlank(m.Priority_Value__c) && !c.severityByPriority.containsKey(m.Priority_Value__c)) {
                c.severityByPriority.put(m.Priority_Value__c, m.Severity__c);
            }
            if (m.Is_Default__c == true && c.defaultSeverity == null) {
                c.defaultSeverity = m.Severity__c;
            }
        }

        // Without a Default setting record: only a breach turns a case Red, no Amber
        // band, no milestone mode, no row cap beyond the controller's query cap.
        if (setting != null) {
            if (setting.Red_Threshold_Minutes__c   != null) c.redThresholdMinutes   = setting.Red_Threshold_Minutes__c;
            if (setting.Amber_Threshold_Percent__c != null) c.amberThresholdPercent = setting.Amber_Threshold_Percent__c;
            c.useCaseMilestones = setting.Use_Case_Milestones__c == true;
            if (setting.Max_Rows__c != null) c.maxRows = setting.Max_Rows__c.intValue();
        }
        return c;
    }

    private static String ruleKey(String severity, String phase) {
        return severity + '|' + phase;
    }

    // ── Settings accessors ─────────────────────────────────────────────────────

    public static Decimal redThresholdMinutes()   { return config().redThresholdMinutes; }
    public static Decimal amberThresholdPercent() { return config().amberThresholdPercent; }
    public static Boolean useCaseMilestones()     { return config().useCaseMilestones; }
    public static Integer maxRows()               { return config().maxRows; }

    // ── Severity ───────────────────────────────────────────────────────────────

    // Manual Severity wins; otherwise map Priority; otherwise the Is_Default mapping.
    public static String resolveSeverity(String severity, String priority) {
        if (String.isNotBlank(severity)) return severity;
        Config c = config();
        if (String.isNotBlank(priority) && c.severityByPriority.containsKey(priority)) {
            return c.severityByPriority.get(priority);
        }
        return c.defaultSeverity;
    }

    // ── Evaluation ─────────────────────────────────────────────────────────────

    public static Result evaluate(CaseInput input) {
        return evaluate(input, DateTime.now());
    }

    public static Result evaluate(CaseInput input, DateTime now) {
        Config c = config();
        Result r = new Result();

        r.severity = resolveSeverity(input.severity, input.priority);
        SLT_Rule__mdt display = r.severity == null ? null : c.displayBySeverity.get(r.severity);
        if (display != null) {
            r.severityLabel     = display.Severity_Label__c;
            r.severityColor     = display.Severity_Color__c;
            r.severitySortOrder = display.Sort_Order__c;
        }

        // Phase and clock start
        if (input.firstResponseDate == null) {
            r.phase     = PHASE_FIRST_RESPONSE;
            r.startTime = input.createdDate;
        } else if (input.lastUpdateDate == null || input.lastUpdateDate == input.firstResponseDate) {
            r.phase     = PHASE_UPDATE;
            r.startTime = input.firstResponseDate;
        } else {
            r.phase     = PHASE_UPDATE;
            r.startTime = input.lastUpdateDate;
        }

        MilestoneInfo m = input.milestone;
        if (c.useCaseMilestones && m != null && m.isCompleted != true
                && m.startDate != null && m.targetDate != null) {
            r.source           = SOURCE_MILESTONE;
            r.startTime        = m.startDate;
            r.deadline         = m.targetDate;
            r.targetMinutes    = minutesBetween(m.startDate, m.targetDate);
            r.elapsedMinutes   = minutesBetween(m.startDate, now);
            r.remainingMinutes = minutesBetween(now, m.targetDate);
        } else {
            r.source = SOURCE_RULE;
            SLT_Rule__mdt rule = r.severity == null ? null : c.ruleByKey.get(ruleKey(r.severity, r.phase));
            if (rule == null || rule.Target_Minutes__c == null || r.startTime == null) {
                r.ruleMissing = true;
                return r;
            }

            r.targetMinutes = rule.Target_Minutes__c;
            Long targetMs   = (rule.Target_Minutes__c * MS_PER_MINUTE).longValue();
            Id   bhId       = rule.Use_Business_Hours__c == true
                ? businessHoursId(rule.Business_Hours_Name__c)
                : null;

            if (bhId != null) {
                r.usesBusinessHours = true;
                r.deadline          = BusinessHours.add(bhId, r.startTime, targetMs);
                r.elapsedMinutes    = BusinessHours.diff(bhId, r.startTime, now) / MS_PER_MINUTE;
            } else {
                r.deadline       = DateTime.newInstance(r.startTime.getTime() + targetMs);
                r.elapsedMinutes = minutesBetween(r.startTime, now);
            }
            r.remainingMinutes = r.targetMinutes - r.elapsedMinutes;
        }

        r.isBreached = r.remainingMinutes <= 0;
        r.ragStatus  = ragFor(r.remainingMinutes, r.targetMinutes, c);
        return r;
    }

    private static String ragFor(Decimal remaining, Decimal window, Config c) {
        if (remaining <= 0)                    return RAG_RED;
        if (remaining < c.redThresholdMinutes) return RAG_RED;
        if (window > 0 && remaining < window * c.amberThresholdPercent / 100) return RAG_AMBER;
        return RAG_GREEN;
    }

    private static Decimal minutesBetween(DateTime fromTime, DateTime toTime) {
        return (toTime.getTime() - fromTime.getTime()) / MS_PER_MINUTE;
    }

    // ── Business hours ─────────────────────────────────────────────────────────

    // Named BusinessHours record, or the org default when blank or not found.
    private static Id businessHoursId(String name) {
        if (businessHoursIdByName == null) {
            businessHoursIdByName = new Map<String, Id>();
            for (BusinessHours bh : [
                SELECT Id, Name, IsDefault
                FROM   BusinessHours
                WHERE  IsActive = true
                WITH   USER_MODE
            ]) {
                businessHoursIdByName.put(bh.Name, bh.Id);
                if (bh.IsDefault) defaultBusinessHoursId = bh.Id;
            }
        }
        if (String.isNotBlank(name) && businessHoursIdByName.containsKey(name)) {
            return businessHoursIdByName.get(name);
        }
        return defaultBusinessHoursId;
    }
}
