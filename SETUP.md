# SF SLT Dashboard — Setup Guide

Complete instructions for deploying the SF SLT Dashboard to a Salesforce org and configuring it for your team.

---

## Prerequisites

- **Salesforce CLI** — [download here](https://developer.salesforce.com/tools/salesforcecli)
- **Node.js** — required by the Salesforce CLI
- **Git**
- For Manager / Technical Lead scopes: a configured **Role hierarchy**
- Optional: **Entitlement Management** (only if you want Case Milestones to define SLT windows)

---

## Part 1 — Terminal

### 1. Clone the repository

```bash
git clone https://github.com/mihai-rus/SF-SLT-Dashboard.git
cd SF-SLT-Dashboard
```

### 2. Authenticate with your Salesforce org

```bash
sf org login web --alias YOUR_ORG_ALIAS
sf org display --target-org YOUR_ORG_ALIAS   # verify
```

### 3. Deploy all metadata

```bash
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

This deploys in one command:
- Custom Metadata Types `SLT_Rule__mdt`, `SLT_Priority_Map__mdt`, `SLT_Setting__mdt` with their default records
- Case custom fields
- Apex classes (`SLTRuleService`, `SLTDashboardController`, `SLTCaseTriggerHandler`) and triggers (`SLTCaseTrigger`, `SLTEmailMessageTrigger`)
- Custom Labels for the scope names
- LWC dashboard component
- Permission sets (base access + 4 scope sets) and custom permissions
- The two legacy Flows (inactive), `Milestone_Type__c` and the legacy formula fields (until removed — see [Removing the legacy formula fields and Flows](#removing-the-legacy-formula-fields-and-flows))

### 4. Run the tests

```bash
sf apex run test \
  --class-names SLTRuleServiceTest \
  --class-names SLTDashboardControllerTest \
  --class-names SLTCaseTriggerHandlerTest \
  --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS \
  --wait 20 \
  --code-coverage \
  --result-format human
```

All tests must pass. The tests inject their own SLT configuration, so they pass regardless of how the SLT metadata records are configured in the org. One test inserts 1,500 cases to measure CPU and takes around 20 seconds.

### 5. Backfill Severity on existing cases (optional)

The dashboard resolves a blank `Severity__c` live from Priority, so existing cases display correctly without a backfill. Run this only if you want `Severity__c` stored on existing open cases (for reports and list views). The executing user needs the `SLTDashboardAccess` permission set.

In **Developer Console → Debug → Open Execute Anonymous Window**:

```apex
List<Case> cases = [
    SELECT Id, Priority, Severity__c
    FROM   Case
    WHERE  IsClosed = false
    AND    Severity__c = null
];
SLTCaseTriggerHandler.applyDefaultSeverity(cases);   // same mapping as new cases
update cases;
```

This works when deployed from source. In a managed-package install, package classes are not callable from anonymous Apex; set Severity with Data Loader or a list-view mass edit instead.

---

## Part 2 — Salesforce Setup

### 1. Review the SLT configuration

Go to **Setup → Custom Metadata Types** and click **Manage Records** next to each type. The defaults reproduce the original hard-coded behaviour:

| Type | Default records |
|---|---|
| SLT Rule | S1: 30 min first response / 240 min update · S2: 120 / 1440 · S3: 1440 / 2160 · business hours off |
| SLT Priority Map | High → S1, Medium → S2, Low → S3 (Low is the default for blank/unmapped Priority) |
| SLT Setting (`Default`) | Red < 60 min, Amber < 40 % of window, Use Case Milestones on, Max Rows 1000 |

Change any value in place — no deployment needed. Field-by-field reference, business hours, milestone mode and adding P1–P4 severities: [DOCUMENTATION.md §5](./DOCUMENTATION.md#5-configuring-slt-rules). Editing requires **Customize Application**.

### 2. Verify the triggers are active

**Setup → Apex Triggers** → confirm **SLTCaseTrigger** and **SLTEmailMessageTrigger** are **Active** (both deploy as active).

### 3. Create the dashboard Lightning page

1. **Setup → Lightning App Builder → New → App Page → Next**
2. Enter a label (e.g. `SLT Dashboard`) → **Next** → **One Region** → **Done**
3. Drag **sfSltDashboard** onto the canvas
4. *(Optional)* In the Properties panel:
   - **Filter by Owner ID** — a User ID to pin the page to one user's cases (overrides scope)
   - **Include Queue ID** — a Queue ID whose open cases are added to every viewer's scope
5. **Save → Activate** → Page Access **Org Default** (or specific apps/profiles), **Desktop** → **Save**

### 4. Add the dashboard to your app navigation

**Setup → App Manager** → your support app → **Edit** → **Navigation Items** → add the page → **Save**.

### 5. Assign permissions to users

Every dashboard user needs **two** permission sets:

| Permission Set | Purpose |
|---|---|
| `SLT Dashboard Access` (`SLTDashboardAccess`) | **Required.** Read access to the SLT Case fields + Apex access |
| One scope set (below) | How many cases the user sees |

> **`SLT Dashboard Access` is mandatory.** The dashboard queries run in *user mode* (field-level security enforced — required for AppExchange security review). A user without it sees **"Unable to load cases"** instead of their cases. A user with base access but no scope set sees their own cases (safe default).

#### Scope permission sets

| Permission Set | Label in UI | Assign to | Dashboard shows |
|---|---|---|---|
| `SLTScope_All` | SLT Dashboard - Director Scope | Directors | All open cases |
| `SLTScope_Org` | SLT Dashboard - Manager Scope | Managers | Every user beneath them in the role hierarchy |
| `SLTScope_Team` | SLT Dashboard - Technical Lead Scope | Technical Leads | Users one level down in the role hierarchy |
| `SLTScope_Own` | SLT Dashboard - Agent Scope | Agents | Own cases |

`SLTScope_Org` and `SLTScope_Team` use the role hierarchy, so those users need their **Role** set (Setup → Users → Edit → Role).

#### Via the UI

**Setup → Users → *user* → Permission Set Assignments → Edit Assignments** → enable `SLT Dashboard Access` and the scope set → **Save**.

For a whole role: **Setup → Permission Sets → *set* → Manage Assignments → Add Assignments**, filter by Role, select users, **Assign**.

#### Via the CLI

```bash
# Director
sf org assign permset --name SLTDashboardAccess --name SLTScope_All \
  --on-behalf-of director@yourorg.com --target-org YOUR_ORG_ALIAS

# Manager
sf org assign permset --name SLTDashboardAccess --name SLTScope_Org \
  --on-behalf-of manager@yourorg.com --target-org YOUR_ORG_ALIAS

# Technical Lead
sf org assign permset --name SLTDashboardAccess --name SLTScope_Team \
  --on-behalf-of lead@yourorg.com --target-org YOUR_ORG_ALIAS

# Agent
sf org assign permset --name SLTDashboardAccess --name SLTScope_Own \
  --on-behalf-of agent@yourorg.com --target-org YOUR_ORG_ALIAS
```

A user should only have one scope set; if they have several, the highest wins (`All → Org → Team → Own`).

### 6. Add SLT fields to the Case page layout (optional)

**Setup → Object Manager → Case → Page Layouts** → add **Severity**, **First Response Date** and **Last Update Date**. (Do not add the legacy formula fields — they are being removed.)

### 7. Know the limits

- Each refresh ranks up to **10,000** open cases in the viewer's scope (oldest first by created date). With more, newer cases are not ranked and the dashboard shows "Showing the most urgent X of 10000+ open cases".
- **Max Rows is effectively capped at 1,500.** Higher values in `SLT_Setting__mdt` behave as 1,500.

---

## Part 3 — After Deploying Updates

### Clearing the Lightning cache

After deploying a new version of the component, users may see the old version until the browser cache is cleared: developer tools → **Application** → **Storage** → **Clear site data**, then reload — or run `localStorage.clear(); sessionStorage.clear();` in the console, or test in a private window.

### Redeploying specific parts

```bash
# LWC only (clear browser cache afterwards)
sf project deploy start --source-dir force-app/main/default/lwc/sfSltDashboard --target-org YOUR_ORG_ALIAS

# Apex classes and triggers
sf project deploy start \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/triggers \
  --target-org YOUR_ORG_ALIAS

# Everything
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

SLT targets, mappings and thresholds are **not** deployed changes — edit them in Setup (Part 2, step 1).

---

## Removing the legacy formula fields and Flows

The original version computed SLTs with four Case formula fields, set Severity and the phase with two Flows, and tracked the phase in `Milestone_Type__c`. Nothing uses them any more. They are removed in two destructive passes:

| Pass | Manifest | Components |
|---|---|---|
| 1 | `manifest/destructiveChanges.xml` | Formula fields `SLT_RAG_Status__c`, `Hours_Remaining__c`, `SLT_Target_Hours__c`, `Hours_Elapsed__c`; Flows `Case_Set_SLT_Fields_On_Create`, `Case_Update_Milestone_On_First_Response` |
| 2 | `manifest/destructiveChanges-pass2.xml` | `Milestone_Type__c` (referenced by the Flow versions, so only removable after pass 1) |

**Do this before the first managed-package release** — components are much harder to remove once they have shipped in a managed package.

### Order of operations

1. **Deploy the new version first** and confirm the dashboard works. `SLTCaseTrigger` must be active — it replaces the Severity Flow. `SLTDashboardAccess` in this repository no longer grants the legacy fields.
2. **Deactivate both Flows.** Deploying a Flow file with `Obsolete` status does not deactivate the running version; set the active version to 0 instead:
   ```bash
   sf project deploy start --metadata-dir manifest/deactivate-flows --target-org YOUR_ORG_ALIAS
   ```
   From here on `SLTCaseTrigger` alone sets Severity on new cases.
3. **Check Flow versions.** Flows are deleted per version (`Name-<version>`). The manifest lists version 1; if the org has more versions, add each one:
   ```bash
   sf data query --use-tooling-api --target-org YOUR_ORG_ALIAS --query \
     "SELECT Definition.DeveloperName, VersionNumber, Status FROM Flow WHERE Definition.DeveloperName IN ('Case_Set_SLT_Fields_On_Create','Case_Update_Milestone_On_First_Response')"
   ```
   Also remove the legacy fields from any page layouts, list views or reports that use them (none in the reference org).
4. **Pass 1 — validate, then run:**
   ```bash
   sf project deploy start --manifest manifest/package.xml \
     --post-destructive-changes manifest/destructiveChanges.xml \
     --target-org YOUR_ORG_ALIAS --dry-run
   # then the same command without --dry-run
   ```
5. **Pass 2 — validate, then run:**
   ```bash
   sf project deploy start --manifest manifest/package.xml \
     --post-destructive-changes manifest/destructiveChanges-pass2.xml \
     --target-org YOUR_ORG_ALIAS --dry-run
   # then the same command without --dry-run
   ```
6. **Delete the source files** — the five field files under `objects/Case/fields/` and both files in `flows/` — and commit, so the next `--source-dir force-app` deploy does not recreate them.
7. *(Optional)* Erase the fields permanently: **Setup → Object Manager → Case → Fields & Relationships → Deleted Fields → Erase**. Deleted fields are otherwise kept for 15 days and count toward the field limit.

## Appendix — Custom Metadata Created (Summary)

| Kind | Items |
|---|---|
| Custom Metadata Types | `SLT_Rule__mdt` (6 records), `SLT_Priority_Map__mdt` (3), `SLT_Setting__mdt` (1) — all fields subscriber-editable |
| Case fields | `Severity__c`, `First_Response_Date__c`, `Last_Update_Date__c`; legacy `Milestone_Type__c` and 4 formula fields (to be removed) |
| Apex classes | `SLTRuleService`, `SLTDashboardController`, `SLTCaseTriggerHandler`, `SLTTestFactory`, `SLTRuleServiceTest`, `SLTDashboardControllerTest`, `SLTCaseTriggerHandlerTest`, `SLTEmailMessageTriggerTest` |
| Apex triggers | `SLTCaseTrigger` (Case, before insert), `SLTEmailMessageTrigger` (EmailMessage, after insert) |
| Custom Labels | `SLT_Scope_Label_Filtered`, `SLT_Scope_Label_All`, `SLT_Scope_Label_Org`, `SLT_Scope_Label_Team`, `SLT_Scope_Label_Own` |
| Custom Permissions | `SLT_Scope_All`, `SLT_Scope_Org`, `SLT_Scope_Team`, `SLT_Scope_Own` |
| Permission Sets | `SLTDashboardAccess`, `SLTScope_All`, `SLTScope_Org`, `SLTScope_Team`, `SLTScope_Own` |
| LWC | `sfSltDashboard` |
| Legacy Flows (to be removed) | `Case_Set_SLT_Fields_On_Create`, `Case_Update_Milestone_On_First_Response` |

`CaseMilestone` and `BusinessHours` are standard Salesforce objects, used but not created by this project.
