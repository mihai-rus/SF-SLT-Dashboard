public with sharing class SLTCaseTriggerHandler {

    // Stamps Severity__c on new cases from SLT_Priority_Map__mdt so reports and
    // list views keep a stored severity. A manually set Severity__c is kept.
    // Only values that exist in the (restricted) Severity__c picklist are written,
    // so a mapping to a severity not yet added to the picklist never blocks an insert;
    // the dashboard still resolves those cases live from Priority.
    public static void applyDefaultSeverity(List<Case> cases) {
        Set<String> allowed = new Set<String>();
        for (Schema.PicklistEntry e : Case.Severity__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) allowed.add(e.getValue());
        }
        for (Case c : cases) {
            if (String.isNotBlank(c.Severity__c)) continue;
            String severity = SLTRuleService.resolveSeverity(null, c.Priority);
            if (severity != null && allowed.contains(severity)) {
                c.Severity__c = severity;
            }
        }
    }
}
