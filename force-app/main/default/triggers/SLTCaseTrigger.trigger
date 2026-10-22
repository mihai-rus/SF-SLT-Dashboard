trigger SLTCaseTrigger on Case (before insert) {
    SLTCaseTriggerHandler.applyDefaultSeverity(Trigger.new);
}
