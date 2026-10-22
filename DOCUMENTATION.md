# SF SLT Dashboard

### Technical Documentation

---

## 1. Product Overview

### What it is

The SF SLT Dashboard is a Salesforce Lightning Web Component (LWC) that gives support agents, technical leads, managers, and directors a live **Red / Amber / Green (RAG)** view of every open Case's Service Level Target (SLT) compliance. Each user sees only the cases relevant to their assigned scope. The dashboard reloads data every 30 seconds and counts down every second in between.

> **RAG** here means Red / Amber / Green — a traffic-light compliance indicator. It is unrelated to AI or retrieval-augmented generation.

### Problem it solves

Support teams must respond to and update cases within contractual time windows that vary by severity (e.g. 30 minutes first response for an S1, 4 hours between updates). Without a single live view, teams cannot easily tell which cases are about to breach their SLT, which have already breached, and which are on track. Managers also need a view scoped to their team or organisation rather than the whole org.

### How it solves it

- **Configurable rules, no code.** Every business rule — targets per severity and phase, Priority → Severity mapping, RAG thresholds, severity colours, business hours, milestone mode, row limit — lives in **Custom Metadata** records that an admin edits in Setup. The product is built to ship as a managed package, where subscribers cannot change Apex, Flows or formulas.
- **One Apex SLT engine.** `SLTRuleService` computes severity, phase, deadline, elapsed and remaining time, and RAG status from that configuration. Countdown, progress bar and RAG badge all come from the same SLT window, so they always agree.
- **Automatic SLT lifecycle.** An Apex trigger on `Case` stamps `Severity__c` on new cases; an Apex trigger on `EmailMessage` stamps response/update timestamps as agents work cases.
- **Role-based scoping.** `SLTDashboardController.getActiveCases` inspects the running user's Custom Permissions and returns only the cases in scope, with a scope label.
- **Live UI.** The `sfSltDashboard` LWC polls the controller every 30 seconds, ticks calendar-time countdowns every second, and renders summary cards, RAG filters, a column picker, sortable columns and a gradient progress bar.

### Who it is for

- **Agents** — see only their own cases.
- **Technical Leads** — see cases for agents one level below them in the role hierarchy.
- **Managers** — see cases for the entire role subtree beneath them.
- **Directors** — see all open cases across the org.

---

## 2. Architecture

This is a **pure-Salesforce** solution. There are no external APIs, no middleware, no scheduled jobs, and no AI components.

### High-level flow

```
Configuration (Setup → Custom Metadata Types)
  ├── SLT_Rule__mdt          — target minutes per Severity × Phase, business hours, label, colour
  ├── SLT_Priority_Map__mdt  — Case Priority → Severity, plus a default
  └── SLT_Setting__mdt       — "Default": Red/Amber thresholds, milestone mode, max rows

New Case Created
  └── Trigger: SLTCaseTrigger (before insert)
        └── Severity__c blank → set from Priority via SLT_Priority_Map__mdt

Agent Sends Outbound Email
  └── Trigger: SLTEmailMessageTrigger (after insert on EmailMessage)
        ├── First outbound email → stamps First_Response_Date__c + Last_Update_Date__c
        └── Later outbound emails → stamps only Last_Update_Date__c

Dashboard Loads / Refreshes (every 30 s)
  └── sfSltDashboard LWC → SLTDashboardController.getActiveCases(ownerId, queueId)
        ├── Scope: ownerId override → "Filtered View"; SLT_Scope_All → all cases;
        │          SLT_Scope_Org → role subtree; SLT_Scope_Team → direct child roles;
        │          fallback → own cases.   queueId adds that queue's cases.
        ├── Stage 1: rank up to 10,000 open cases by a calendar-time estimate
        ├── Stage 2: exact SLTRuleService.evaluate() for the top candidates
        └── Returns DashboardResult { cases, scopeLabel, totalCaseCount, isTruncated,
                                      redThresholdMinutes, amberThresholdPercent }

Between refreshes (every 1 s, in the browser)
  └── Calendar-time rows count down from their deadline and recompute RAG locally
```

### Sharing and security model

- **Apex sharing.** All classes are `with sharing`; every SOQL query runs `WITH USER_MODE` (or `AccessLevel.USER_MODE` for dynamic SOQL), so record access, object permissions **and field-level security** of the running user are enforced. This is required for AppExchange security review.
- **Users therefore need `SLTDashboardAccess`.** Because queries run in user mode, a user without read access to the SLT Case fields gets an error instead of data. The `SLTDashboardAccess` permission set grants that access plus Apex class access. See [Access Control](#10-access-control).
- **Custom metadata needs no user permission.** Apex reads `SLT_*__mdt` with `getAll()` / `getInstance()`; users do not need any permission on the metadata types. Editing the records requires **Customize Application**.
- **Scope enforcement.** Scope is determined by Custom Permissions checked via `FeatureManagement.checkPermission(...)`, highest first (`All → Org → Team → Own`).

---

## 3. Technology Stack

| Layer | Technology |
|---|---|
| Frontend | Lightning Web Components (JavaScript, HTML templates, scoped CSS) |
| Backend | Apex: `SLTRuleService`, `SLTDashboardController`, `SLTCaseTriggerHandler` |
| Triggers | `SLTCaseTrigger` (Case, before insert), `SLTEmailMessageTrigger` (EmailMessage, after insert) |
| Configuration | Custom Metadata Types `SLT_Rule__mdt`, `SLT_Priority_Map__mdt`, `SLT_Setting__mdt` |
| Labels | Custom Labels `SLT_Scope_Label_*` (scope names, translatable) |
| Tooling | Salesforce DX source format, Salesforce CLI (`sf`) |
| API version | 62.0 (`sourceApiVersion`, Apex classes, LWC bundle) |

### Salesforce platform features used

- **Lightning Web Components** — exposed to App Page, Home Page, and Record Page (Case and User). App Builder properties: `ownerId`, `queueId`.
- **Custom Metadata Types** — subscriber-editable configuration (every field is *Subscriber editable*, records are not protected).
- **`BusinessHours.add` / `BusinessHours.diff`** — business-hours SLT clocks.
- **Standard `CaseMilestone` (Entitlement Management)** — optional. Read through dynamic SOQL only when the object exists, so the package does **not** depend on Entitlement Management being enabled.
- **Custom Permissions, Permission Sets, Custom Labels.**

---

## 4. SLT Engine (`SLTRuleService`)

All SLT logic lives in `SLTRuleService.cls`. Configuration is loaded once per transaction (static cache) via `SLT_Rule__mdt.getAll()`, `SLT_Priority_Map__mdt.getAll()` and `SLT_Setting__mdt.getInstance('Default')` — no SOQL against custom metadata.

### Step 1 — Severity

1. `Case.Severity__c` if populated (manual override wins).
2. Otherwise `Case.Priority` looked up in `SLT_Priority_Map__mdt.Priority_Value__c`.
3. Otherwise the `SLT_Priority_Map__mdt` record with `Is_Default__c = true`.

### Step 2 — Phase and clock start

| Case state | Phase | Clock starts at |
|---|---|---|
| `First_Response_Date__c` blank | First Response | `CreatedDate` |
| First response sent, `Last_Update_Date__c` blank or equal to it | Update | `First_Response_Date__c` |
| Otherwise | Update | `Last_Update_Date__c` |

### Step 3 — SLT window

- **Milestone mode** — if `SLT_Setting__mdt.Use_Case_Milestones__c` is true and the case has an open `CaseMilestone` with a `TargetDate`, the window is the milestone's `StartDate → TargetDate` (Source = *Milestone*). No SLT rule is needed in this case.
- **Rule mode** — otherwise the active `SLT_Rule__mdt` matching Severity × Phase supplies `Target_Minutes__c` (Source = *Rule*):
  - `Use_Business_Hours__c = false` → deadline = start + target, elapsed = now − start (calendar time).
  - `Use_Business_Hours__c = true` → deadline = `BusinessHours.add(bh, start, target)`, elapsed = `BusinessHours.diff(bh, start, now)`. `bh` is the `BusinessHours` record named in `Business_Hours_Name__c`, or the org default when blank or not found.
- **No rule** — no active rule for Severity × Phase (and no milestone) → `ruleMissing = true`, no RAG status. The dashboard shows a grey **No SLT rule** badge, never Red.

### Step 4 — RAG

Computed from the same window in both modes:

```
remaining ≤ 0                                         → Red   (breached)
remaining < Red_Threshold_Minutes__c                  → Red
remaining < window × Amber_Threshold_Percent__c / 100 → Amber
otherwise                                             → Green
```

If the `Default` setting record is missing, both thresholds are 0 (only a breach is Red), milestone mode is off, and the row limit is the engine maximum (1,500).

### Result

`severity`, `severityLabel`, `severityColor`, `severitySortOrder`, `phase`, `startTime`, `deadline`, `targetMinutes`, `elapsedMinutes`, `remainingMinutes`, `ragStatus`, `isBreached`, `source` (`Rule` | `CaseMilestone`), `ruleMissing`, `usesBusinessHours`.

---

## 5. Configuring SLT rules

All rules are edited in **Setup → Custom Metadata Types → *type* → Manage Records**. Changes take effect on the next dashboard refresh; no deployment is needed. Editing requires the **Customize Application** permission.

### `SLT_Rule__mdt` — one record per Severity × Phase

| Field | Meaning |
|---|---|
| Severity (`Severity__c`) | Severity value, e.g. `S1`. Must match the `Case.Severity__c` / priority-map value exactly. |
| Phase (`Phase__c`) | `First Response` or `Update` |
| Target Minutes (`Target_Minutes__c`) | Target for this severity and phase, in minutes |
| Use Business Hours (`Use_Business_Hours__c`) | Clock only runs inside business hours |
| Business Hours Name (`Business_Hours_Name__c`) | Name of a Business Hours record; blank = org default |
| Severity Label (`Severity_Label__c`) | Tooltip on the severity pill, e.g. "Production Down" |
| Severity Color (`Severity_Color__c`) | Hex colour of the severity pill, e.g. `#8E0A08` (see below) |
| Sort Order (`Sort_Order__c`) | 1 = most severe |
| Active (`Active__c`) | Inactive records are ignored |

**Default records** (reproduce the original behaviour; business hours off):

| Record | Severity | Phase | Target Minutes | Label | Color | Sort |
|---|---|---|---|---|---|---|
| S1_First_Response | S1 | First Response | 30 | Production Down | `#8E0A08` | 1 |
| S1_Update | S1 | Update | 240 | Production Down | `#8E0A08` | 1 |
| S2_First_Response | S2 | First Response | 120 | Production Impaired | `#7A4600` | 2 |
| S2_Update | S2 | Update | 1440 | Production Impaired | `#7A4600` | 2 |
| S3_First_Response | S3 | First Response | 1440 | Minor Issue | `#005FB2` | 3 |
| S3_Update | S3 | Update | 2160 | Minor Issue | `#005FB2` | 3 |

Label, colour and sort order are read from the first active rule found for a severity, so keep them identical on both phase records.

**Severity colour.** If text in the colour is readable on white (WCAG AA), the pill shows the colour as text on a light tint of itself; otherwise the pill is filled with the colour and uses black or white text. An invalid or blank value falls back to the built-in `sev-s1/s2/s3` styles.

### `SLT_Priority_Map__mdt` — Case Priority → Severity

| Record | Priority Value | Severity | Is Default |
|---|---|---|---|
| High | High | S1 | |
| Medium | Medium | S2 | |
| Low | Low | S3 | ✓ |

The *Is Default* record is used when Priority is blank or has no mapping. Mark exactly one record as default.

### `SLT_Setting__mdt` — record `Default`

| Field | Default | Meaning |
|---|---|---|
| Red Threshold Minutes | 60 | Red when fewer minutes than this remain |
| Amber Threshold Percent | 40 | Amber when less than this % of the window remains |
| Use Case Milestones | ✓ | Use an open `CaseMilestone` as the SLT window when one exists |
| Max Rows | 1000 | Most-urgent cases returned to the dashboard (effective maximum 1,500 — see [Limits](#11-limits-and-performance)) |

### Adding P1–P4 style severities

1. **Severity picklist** — Setup → Object Manager → Case → Fields & Relationships → Severity → add `P1`…`P4` (the field is a restricted picklist; values that are not in it cannot be stored on the case).
2. **Rules** — create `SLT_Rule__mdt` records for every new severity × phase (e.g. `P1_First_Response`, `P1_Update`, …) with targets, label, colour and sort order. Deactivate the `S1`–`S3` records if they are no longer used.
3. **Priority map** — edit `SLT_Priority_Map__mdt` so each Priority value maps to the new severities, and move *Is Default* to the right record. Add Priority values to the Case Priority picklist first if needed.
4. **Existing cases** — open cases keep their stored `Severity__c`. Re-map them with the backfill script in SETUP.md (clear `Severity__c` first) or update them manually.

### Business hours

Set `Use_Business_Hours__c` on a rule to pause its clock outside working hours. Leave `Business_Hours_Name__c` blank for the org default (Setup → Business Hours) or enter the exact name of another active record; an unknown name falls back to the default. Business-hours rows do not tick every second in the browser (their clock may be paused); they update on each 30-second refresh.

### Milestone mode

With `Use_Case_Milestones__c` checked, a case's earliest-due **open** `CaseMilestone` with a `TargetDate` defines the SLT window (`StartDate → TargetDate`, calendar time), and the Milestone Name / Target Date / Violated columns come from it. The entitlement process's own business hours are already reflected in `TargetDate`. Completed milestones are ignored. Uncheck it to use SLT rules for every case even where entitlements exist. Orgs without Entitlement Management simply never have milestones.

---

## 6. Dashboard controller (`SLTDashboardController`)

### `getActiveCases(String ownerId, String queueId)` — `@AuraEnabled(cacheable=true)`

| Priority | Condition | Cases | Scope label (Custom Label) |
|---|---|---|---|
| 1 | `ownerId` set in App Builder | That user's cases | `SLT_Scope_Label_Filtered` — "Filtered View" |
| 2 | `SLT_Scope_All` | All open cases | `SLT_Scope_Label_All` — "All Cases" |
| 3 | `SLT_Scope_Org` | Users in the role subtree beneath the user, plus the user | `SLT_Scope_Label_Org` — "Your Organisation" |
| 4 | `SLT_Scope_Team` | Users in direct child roles, plus the user | `SLT_Scope_Label_Team` — "Your Team" |
| 5 | Fallback | The user's own cases | `SLT_Scope_Label_Own` — "Your Cases" |

`queueId` (optional) adds open cases owned by that queue to rows 1 and 3–5 (the All scope already includes them). A value that is not a Queue Id raises an error. Open = `IsClosed = false`.

### Two-stage ranking

1. **Stage 1** — up to **10,000** open cases in scope (oldest first, by `CreatedDate`) are read with a SOQL for-loop and ranked by `SLTRuleService.estimate()`: the same calculation in calendar time, with no `BusinessHours` calls (~0.1 ms CPU per case). Business-hours elapsed time never exceeds calendar elapsed time, so the estimate never reports *more* time left than the exact value.
2. **Stage 2** — the top `Max_Rows__c + 250` candidates (never more than 1,500) are evaluated exactly (business hours included, ~2.2 ms CPU per case), sorted by remaining time ascending (breached first, no-rule rows last) and cut to `Max_Rows__c`.

`DashboardResult.totalCaseCount` is the number of open cases ranked; `isTruncated` is true when stage 1 hit the 10,000 cap. The caps are code constants (`QUERY_ROW_CAP`, `EXACT_ROW_CAP`, `CANDIDATE_MARGIN`).

### `CaseRow`

Existing properties: `caseId`, `caseNumber`, `subject`, `ownerName`, `status`, `milestoneName`, `targetDate`, `timeRemainingMins`, `isViolated`, `completionDate`, `ragStatus`, `severity`, `sltTargetHours`, `hoursElapsed`, `hoursRemaining`. New: `severityLabel`, `severityColor`, `severitySortOrder`, `deadline`, `source`, `ruleMissing`, `usesBusinessHours`.

- Milestone rows: `milestoneName`, `targetDate`, `completionDate`, `isViolated` come from the open milestone (Completion Date is therefore normally empty).
- Rule rows: `milestoneName` = engine phase, `targetDate` empty, `isViolated` = breached.

---

## 7. LWC (`sfSltDashboard`)

- **Refresh** — `getActiveCases` every 30 s (`REFRESH_INTERVAL_MS`).
- **Live countdown** — every 1 s (`TICK_INTERVAL_MS`) calendar-time rows recompute remaining time from `deadline`, plus RAG (using `redThresholdMinutes` / `amberThresholdPercent` from the server), Violated and progress. Under one hour remaining, these rows show seconds (`42m 15s`). Business-hours and no-rule rows keep server values until the next refresh. The table re-renders only when a visible value changes. Both timers are cleared in `disconnectedCallback`.
- **No SLT rule** — grey badge, `—` for time remaining, excluded from the Critical / At Risk / On Track counts and filters (still counted in Total Active).
- **Severity pill** — colour from `severityColor`, tooltip from `severityLabel`.
- **Source column** — Rule / Milestone; hidden by default in the column picker.
- **Truncation note** — "Showing the most urgent X of Y+ open cases" when the 10,000 cap was hit, "… of Y open cases" when only `Max_Rows__c` cut the list.

| Constant (`sfSltDashboard.js`) | Purpose |
|---|---|
| `REFRESH_INTERVAL_MS` | Server refresh interval (30000) |
| `TICK_INTERVAL_MS` | Client countdown interval (1000) |
| `RAG_LABEL`, `NO_RULE_LABEL` | Badge labels |
| `DEFAULT_COLUMNS` | Columns and default visibility (13, Source hidden) |

---

## 8. File Structure

```
SLT_Dashboard_v1/
├── README.md / SETUP.md / DOCUMENTATION.md / DOCUMENTATION_BUSINESS.md
├── sfdx-project.json                    # sourceApiVersion 62.0
├── manifest/
│   ├── package.xml                      # empty carrier for the destructive change
│   └── destructiveChanges.xml           # legacy formula fields + Flows (see SETUP.md)
└── force-app/main/default/
    ├── classes/
    │   ├── SLTRuleService.cls                # SLT engine
    │   ├── SLTDashboardController.cls        # scope, two-stage ranking, CaseRow
    │   ├── SLTCaseTriggerHandler.cls         # Severity__c from Priority on insert
    │   ├── SLTTestFactory.cls                # @isTest in-memory configuration
    │   ├── SLTRuleServiceTest.cls / SLTDashboardControllerTest.cls
    │   └── SLTCaseTriggerHandlerTest.cls / SLTEmailMessageTriggerTest.cls
    ├── triggers/
    │   ├── SLTCaseTrigger.trigger            # Case before insert
    │   └── SLTEmailMessageTrigger.trigger    # EmailMessage after insert
    ├── objects/
    │   ├── SLT_Rule__mdt/ SLT_Priority_Map__mdt/ SLT_Setting__mdt/
    │   └── Case/fields/                      # Severity__c, Milestone_Type__c, First_Response_Date__c,
    │                                         # Last_Update_Date__c (+ 4 legacy formula fields)
    ├── customMetadata/                       # 6 rules, 3 priority maps, 1 setting
    ├── labels/CustomLabels.labels-meta.xml   # SLT_Scope_Label_*
    ├── flows/                                # 2 legacy Flows (to be removed)
    ├── customPermissions/                    # SLT_Scope_All / Org / Team / Own
    ├── permissionsets/                       # SLTDashboardAccess + 4 scope sets
    └── lwc/sfSltDashboard/
```

---

## 9. SLT Lifecycle (Automation)

| Component | Type | When | What |
|---|---|---|---|
| `SLTCaseTrigger` → `SLTCaseTriggerHandler` | Apex trigger, before insert on Case | Every new case with blank `Severity__c` | Sets `Severity__c` from Priority via `SLT_Priority_Map__mdt`. Only writes values that exist in the `Severity__c` picklist, so a mapping to a severity not yet added to the picklist never blocks case creation (the dashboard still resolves it live). |
| `SLTEmailMessageTrigger` | Apex trigger, after insert on EmailMessage | Outbound email with a Case parent | Stamps `Last_Update_Date__c` (always) and `First_Response_Date__c` (first time only) |

- **Phase 1 — waiting for first response.** Clock runs from `CreatedDate` against the First Response rule.
- **Phase 2 — first response given.** The first outbound email stamps both dates; the case switches to the Update rule with a fresh window.
- **Phase 3 — ongoing updates.** Each outbound email re-stamps `Last_Update_Date__c`, restarting the update window.
- Only Salesforce-originated **outbound** `EmailMessage` records reset the clock; emails sent from Outlook/Gmail outside Salesforce do not.
- Severity is stamped once at creation. Changing Priority later does not change the stored `Severity__c`; edit Severity directly if needed.

---

## 10. Access Control

### Two permission sets per user

| Set | API name | Grants |
|---|---|---|
| Base access (**required**) | `SLTDashboardAccess` | Read on the SLT Case fields + Apex access to `SLTDashboardController` |
| One scope set | one of the four below | How much data the user sees |

> **`SLTDashboardAccess` is mandatory.** All queries run in user mode, so field-level security is enforced. A user without it sees "Unable to load cases" instead of their cases. Users without a scope set still see their own cases (safe default).

| Permission Set (API) | Label | Custom Permission | Cases shown |
|---|---|---|---|
| `SLTScope_All` | SLT Dashboard - Director Scope | `SLT_Scope_All` | All open cases |
| `SLTScope_Org` | SLT Dashboard - Manager Scope | `SLT_Scope_Org` | Role subtree beneath the user |
| `SLTScope_Team` | SLT Dashboard - Technical Lead Scope | `SLT_Scope_Team` | Direct child roles |
| `SLTScope_Own` | SLT Dashboard - Agent Scope | `SLT_Scope_Own` | Own cases |

**Admins** who edit SLT configuration need **Customize Application** (Setup → Custom Metadata Types). The Case trigger runs in system context and needs no user permission.

### App Builder properties

| Property | Effect |
|---|---|
| Filter by Owner ID (`ownerId`) | Pins the dashboard to one user's cases for everyone viewing the page ("Filtered View") |
| Include Queue ID (`queueId`) | Adds open cases owned by this queue to the viewer's scope |

---

## 11. Limits and Performance

| Limit | Value | Notes |
|---|---|---|
| Cases ranked per request | 10,000 (`QUERY_ROW_CAP`) | Oldest 10,000 open cases in scope by `CreatedDate`. Beyond that, newer cases are not ranked; the dashboard then says "… of 10000+ open cases". |
| Exact evaluations | 1,500 (`EXACT_ROW_CAP`) | Top `Max_Rows__c + 250` candidates from stage 1 |
| Rows returned | `Max_Rows__c`, **effectively capped at 1,500** | Higher values behave as 1,500 |
| Candidate margin | 250 (`CANDIDATE_MARGIN`) | A truly urgent case can be missed only if more than 250 business-hours cases look more urgent in calendar time than they are (e.g. many cases opened late on a Friday) |

Measured CPU (all rules on business hours, debug logging minimal): 10,000 cases ranked + 1,250 exact ≈ 4.0 s of the 10 s synchronous limit, heap ≈ 1.5 MB; end to end with 1,500 real cases ≈ 3.1–3.5 s. Calendar-only configurations are far cheaper. Heavy debug logging (`APEX_CODE=FINEST`) roughly doubles business-hours CPU cost.

---

## 12. Edge Cases

- **Pre-deployment cases without Severity** — resolved live from Priority by the engine; run the backfill script in SETUP.md if you also want `Severity__c` stored for reports.
- **Severity with no active rule** — "No SLT rule" badge, excluded from RAG counts, listed last.
- **Missing `Default` setting record** — only breaches are Red, no Amber band, milestone mode off.
- **No `CaseMilestone` / no Entitlement Management** — rules are used for every case.
- **Inbound-only cases** — stay in the First Response phase.
- **Client clock** — live countdowns use the browser clock between refreshes; a skewed device clock shifts them until the next refresh.
- **Stale browser cache** — after deploying a new LWC version, clear site data or test in a private window.

---

## 13. Custom Metadata Created (Summary)

Standard objects/fields used as-is (Case, EmailMessage, CaseMilestone, BusinessHours, Priority, Status, OwnerId, CreatedDate, IsClosed) are not listed.

### Custom Metadata Types (3) and records (10)

| Type | Fields | Records |
|---|---|---|
| `SLT_Rule__mdt` | `Severity__c`, `Phase__c`, `Target_Minutes__c`, `Use_Business_Hours__c`, `Business_Hours_Name__c`, `Severity_Label__c`, `Severity_Color__c`, `Sort_Order__c`, `Active__c` | 6 (S1–S3 × First Response/Update) |
| `SLT_Priority_Map__mdt` | `Priority_Value__c`, `Severity__c`, `Is_Default__c` | 3 (High, Medium, Low) |
| `SLT_Setting__mdt` | `Red_Threshold_Minutes__c`, `Amber_Threshold_Percent__c`, `Use_Case_Milestones__c`, `Max_Rows__c` | 1 (Default) |

All fields are subscriber-editable; records are not protected.

### Custom fields on Case

| Field | Type | Purpose |
|---|---|---|
| `Severity__c` | Picklist (S1/S2/S3) | Stored severity; set by `SLTCaseTrigger` or manually |
| `First_Response_Date__c` | DateTime | Stamped on first outbound email |
| `Last_Update_Date__c` | DateTime | Stamped on every outbound email |
| `Milestone_Type__c` | Picklist | Legacy phase indicator; no longer used by the dashboard and no longer maintained once the Flows are removed |
| `SLT_Target_Hours__c`, `Hours_Elapsed__c`, `Hours_Remaining__c`, `SLT_RAG_Status__c` | Formula | **Legacy** — not used by any code; removed by `manifest/destructiveChanges.xml` |

### Apex classes (8)

`SLTRuleService`, `SLTDashboardController`, `SLTCaseTriggerHandler`, `SLTTestFactory`, `SLTRuleServiceTest`, `SLTDashboardControllerTest`, `SLTCaseTriggerHandlerTest`, `SLTEmailMessageTriggerTest`

### Apex triggers (2)

`SLTCaseTrigger` (Case, before insert), `SLTEmailMessageTrigger` (EmailMessage, after insert)

### Custom Labels (5)

`SLT_Scope_Label_Filtered`, `SLT_Scope_Label_All`, `SLT_Scope_Label_Org`, `SLT_Scope_Label_Team`, `SLT_Scope_Label_Own`

### Custom Permissions (4) and Permission Sets (5)

`SLT_Scope_All`, `SLT_Scope_Org`, `SLT_Scope_Team`, `SLT_Scope_Own`; `SLTDashboardAccess`, `SLTScope_All`, `SLTScope_Org`, `SLTScope_Team`, `SLTScope_Own`

### Lightning Web Component (1)

`sfSltDashboard`

### Legacy (to be removed)

Flows `Case_Set_SLT_Fields_On_Create` and `Case_Update_Milestone_On_First_Response`, and the four formula fields above — see SETUP.md, "Removing the legacy formula fields and Flows".
