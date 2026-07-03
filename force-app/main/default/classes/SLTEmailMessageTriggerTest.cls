@isTest
private class SLTEmailMessageTriggerTest {

    private static Case makeCase(String subject) {
        return new Case(Subject = subject, Status = 'New');
    }

    @isTest
    static void outboundEmailStampsBothDatesWhenNoFirstResponse() {
        Case c = makeCase('First Outbound Email Test');
        insert c;

        Test.startTest();
        insert new EmailMessage(
            ParentId    = c.Id,
            Subject     = 'Agent reply',
            TextBody    = 'Here is your update.',
            Incoming    = false,
            ToAddress   = 'customer@example.com',
            FromAddress = 'agent@support.example.com'
        );
        Test.stopTest();

        Case updated = [SELECT First_Response_Date__c, Last_Update_Date__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.First_Response_Date__c,
            'First_Response_Date__c must be stamped on first outbound email');
        System.assertNotEquals(null, updated.Last_Update_Date__c,
            'Last_Update_Date__c must be stamped on first outbound email');
    }

    @isTest
    static void outboundEmailDoesNotOverwriteExistingFirstResponse() {
        Case c = makeCase('Subsequent Outbound Email Test');
        insert c;
        DateTime originalFirstResponse = DateTime.now().addHours(-1);
        update new Case(Id = c.Id, First_Response_Date__c = originalFirstResponse);

        Test.startTest();
        insert new EmailMessage(
            ParentId    = c.Id,
            Subject     = 'Follow-up',
            TextBody    = 'Another update.',
            Incoming    = false,
            ToAddress   = 'customer@example.com',
            FromAddress = 'agent@support.example.com'
        );
        Test.stopTest();

        Case updated = [SELECT First_Response_Date__c, Last_Update_Date__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(originalFirstResponse, updated.First_Response_Date__c,
            'First_Response_Date__c must NOT be overwritten on subsequent outbound emails');
        System.assertNotEquals(null, updated.Last_Update_Date__c,
            'Last_Update_Date__c must still be stamped');
    }

    @isTest
    static void inboundEmailDoesNotStampAnyDate() {
        Case c = makeCase('Inbound Email Test');
        insert c;

        Test.startTest();
        insert new EmailMessage(
            ParentId    = c.Id,
            Subject     = 'Customer question',
            TextBody    = 'Hello, I need help.',
            Incoming    = true,
            ToAddress   = 'support@example.com',
            FromAddress = 'customer@example.com'
        );
        Test.stopTest();

        Case updated = [SELECT First_Response_Date__c, Last_Update_Date__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, updated.First_Response_Date__c,
            'First_Response_Date__c must NOT be stamped on inbound email');
        System.assertEquals(null, updated.Last_Update_Date__c,
            'Last_Update_Date__c must NOT be stamped on inbound email');
    }

    @isTest
    static void bulkOutboundEmailsHandledEfficiently() {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 10; i++) {
            cases.add(makeCase('Bulk Case ' + i));
        }
        insert cases;

        List<EmailMessage> emails = new List<EmailMessage>();
        for (Case c : cases) {
            emails.add(new EmailMessage(
                ParentId    = c.Id,
                Subject     = 'Bulk reply',
                TextBody    = 'Update.',
                Incoming    = false,
                ToAddress   = 'customer@example.com',
                FromAddress = 'agent@support.example.com'
            ));
        }

        Test.startTest();
        insert emails;
        Test.stopTest();

        List<Case> updated = [SELECT First_Response_Date__c, Last_Update_Date__c FROM Case WHERE Id IN :new Map<Id,Case>(cases).keySet()];
        for (Case c : updated) {
            System.assertNotEquals(null, c.First_Response_Date__c,
                'First_Response_Date__c must be stamped for every case: ' + c.Id);
            System.assertNotEquals(null, c.Last_Update_Date__c,
                'Last_Update_Date__c must be stamped for every case: ' + c.Id);
        }
    }
}
