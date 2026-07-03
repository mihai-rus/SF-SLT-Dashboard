trigger SLTEmailMessageTrigger on EmailMessage (after insert) {
    Set<Id> caseIds = new Set<Id>();
    for (EmailMessage em : Trigger.new) {
        if (!em.Incoming
                && em.ParentId != null
                && String.valueOf(em.ParentId).startsWith('500')) {
            caseIds.add(em.ParentId);
        }
    }
    if (caseIds.isEmpty()) return;

    Map<Id, Case> caseMap = new Map<Id, Case>(
        [SELECT Id, First_Response_Date__c FROM Case WHERE Id IN :caseIds]
    );

    DateTime now = DateTime.now();
    List<Case> toUpdate = new List<Case>();
    for (Id cid : caseIds) {
        Case upd = new Case(Id = cid, Last_Update_Date__c = now);
        if (caseMap.get(cid).First_Response_Date__c == null) {
            upd.First_Response_Date__c = now;
        }
        toUpdate.add(upd);
    }
    update toUpdate;
}
