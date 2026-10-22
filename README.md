# SF SLT Dashboard — Salesforce LWC

A Lightning Web Component that gives support agents and managers a live **Red / Amber / Green** view of every open case's SLT compliance. Each user sees only the cases relevant to their assigned scope. Data refreshes every 30 seconds and countdowns tick every second — no manual page refresh.

Every SLT rule (targets, Priority → Severity mapping, RAG thresholds, colours, business hours) is **configuration in Setup**, not code, so the product can ship as a managed package.

> **RAG** here means Red / Amber / Green — a traffic-light compliance indicator. It has nothing to do with AI or retrieval-augmented generation.

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [Role-based scoping](#2-role-based-scoping)
3. [How SLT tracking works — the full lifecycle](#3-how-slt-tracking-works--the-full-lifecycle)
4. [Tech stack and architecture](#4-tech-stack-and-architecture)
5. [Configuring SLT rules](#5-configuring-slt-rules)
6. [Automation](#6-automation)
7. [Apex](#7-apex)
8. [LWC dashboard component](#8-lwc-dashboard-component)
9. [Permission sets](#9-permission-sets)
10. [Limits](#10-limits)
11. [Deploy and setup](#11-deploy-and-setup)
12. [Configuration reference](#12-configuration-reference)
13. [Edge cases](#13-edge-cases)
14. [Custom Metadata Created (Summary)](#14-custom-metadata-created-summary)

---

## 1. What it does

| Feature | Detail |
|---|---|
| Role-based scope | Each user automatically sees the right cases for their role — Agent, Technical Lead, Manager, or Director |
| Scope label | Header shows "Viewing: Your Team" / "Your Organisation" / "All Cases" etc. (Custom Labels, translatable) |
| Live case table | Most urgent open cases first, sortable by any column |
| 13 available columns | Case #, Subject, Owner, Status, Severity, Milestone Name, Target Date, Time Remaining, Progress, Violated, Completion Date, RAG Status, Source (hidden by default) |
| Column picker | Show or hide any column via the Columns button |
| Summary cards | Counts of Total / Critical / At Risk / On Track cases |
| RAG filter buttons | Filter the table to Critical, At Risk, or On Track |
| Live countdown | Time remaining ticks every second (`42m 15s` under an hour; `Xh Ym` above), RAG badge updates as thresholds are crossed |
| Gradient progress bar | Green → orange → red as the SLT deadline approaches |
| Configurable severities | Severity pill colour and label come from configuration |
| Business hours | Optional per rule — clock pauses outside working hours |
| Entitlement milestones | Optional — an open Case Milestone can define the SLT window |
| "No SLT rule" badge | Cases whose severity has no rule are flagged grey, never shown as Red |
| Queue cases | Optionally include a queue's cases in the view |
| Automatic SLT reset | Timer resets when an outbound email is sent from the case |
| Priority mapping | New cases get Severity from Priority |

### Available columns

| Column | Source |
|---|---|
| Case # / Subject / Owner / Status | Case fields |
| Severity | Resolved severity (stored `Severity__c`, else Priority mapping); pill colour from `SLT_Rule__mdt` |
| Milestone Name | Open `CaseMilestone` name, or the SLT phase (First Response / Update) |
| Target Date | Open `CaseMilestone.TargetDate` (blank for rule-based rows) |
| Time Remaining | Deadline − now |
| Progress | Elapsed ÷ SLT window |
| Violated | Milestone `IsViolated`, or deadline passed |
| Completion Date | Milestone completion date (open milestones only, so normally blank) |
| RAG Status | Red / Amber / Green from the SLT window, or "No SLT rule" |
| Source | Rule or Milestone (hidden by default) |

---

## 2. Role-based scoping

| Scope | Permission Set to assign | What the user sees |
|---|---|---|
| Director | `SLT Dashboard - Director Scope` | All open cases in the org |
| Manager | `SLT Dashboard - Manager Scope` | Cases for every user beneath them in the role hierarchy |
| Technical Lead | `SLT Dashboard - Technical Lead Scope` | Cases for users in direct child roles |
| Agent | `SLT Dashboard - Agent Scope` | Only their own cases |
| *(no scope assigned)* | — | Only their own cases (safe default) |

The controller checks `SLT_Scope_All → SLT_Scope_Org → SLT_Scope_Team → fallback`; the highest scope wins. Manager and Technical Lead scopes traverse the role hierarchy at runtime, so those users need a Role.

### Every user also needs `SLT Dashboard Access`

Queries run in **user mode** (field-level security enforced, required for AppExchange). Without the `SLTDashboardAccess` permission set a user gets "Unable to load cases". See [SETUP.md](./SETUP.md).

### Admin overrides (Lightning App Builder)

- **Filter by Owner ID** — pins the page to one user's cases for everyone ("Viewing: Filtered View").
- **Include Queue ID** — adds open cases owned by that queue to each viewer's scope.

---

## 3. How SLT tracking works — the full lifecycle

### Phase 1 — Waiting for first response
The clock starts at case creation against the **First Response** target for the case's severity (e.g. 30 minutes for S1).

### Phase 2 — First response given
When an agent **sends an outbound email** from the case, `First_Response_Date__c` and `Last_Update_Date__c` are stamped, the target switches to the **Update** target (e.g. 4 hours for S1) and the clock restarts.

### Phase 3 — Ongoing updates
Every subsequent outbound email re-stamps `Last_Update_Date__c` and restarts the update window.

Emails sent from an external client (Outlook, Gmail, …) do not create a Salesforce `EmailMessage` and do not reset the timer.

### RAG status (default thresholds)

- **Green / On track** — at least 40% of the SLT window remains
- **Amber / At risk** — less than 40% of the window remains
- **Red / Critical** — less than 60 minutes remain, or the SLT is breached
- **Grey / No SLT rule** — no rule is configured for the case's severity and phase

Both thresholds are configurable (`SLT_Setting__mdt`).

---

## 4. Tech stack and architecture

| Layer | Technology | Purpose |
|---|---|---|
| Configuration | Custom Metadata Types | SLT rules, priority mapping, thresholds |
| Engine | Apex `SLTRuleService` | Severity, phase, deadline, elapsed/remaining, RAG |
| Backend | Apex `SLTDashboardController` | Scope, two-stage ranking, rows for the LWC |
| Automation | Apex triggers on Case and EmailMessage | Stamp Severity on create; stamp response/update dates |
| Data | Salesforce CaseMilestone (optional) | Milestone-based SLT windows |
| Access | `SLTDashboardAccess` + 4 scope permission sets | Field access and scope |
| Frontend | LWC `sfSltDashboard` | Dashboard UI |

```
Setup → Custom Metadata (SLT_Rule, SLT_Priority_Map, SLT_Setting)
                     │
New Case ──► SLTCaseTrigger ──► Severity__c from Priority
Outbound email ──► SLTEmailMessageTrigger ──► First_Response / Last_Update dates
                     │
Dashboard (30 s) ──► SLTDashboardController.getActiveCases(ownerId, queueId)
                       ├── scope from Custom Permissions
                       ├── rank up to 10,000 open cases (calendar-time estimate)
                       └── exact SLTRuleService evaluation of the most urgent
Browser (1 s) ──► countdown + RAG for calendar-time rows
```

---

## 5. Configuring SLT rules

Everything is edited in **Setup → Custom Metadata Types → *type* → Manage Records** — no code, no deployment. Full field reference: [DOCUMENTATION.md §5](./DOCUMENTATION.md#5-configuring-slt-rules).

### Default SLT targets (`SLT_Rule__mdt`)

| Severity | First Response target | Update target | Label | Colour |
|---|---|---|---|---|
| S1 | 30 minutes | 4 hours (240) | Production Down | `#8E0A08` |
| S2 | 2 hours (120) | 24 hours (1440) | Production Impaired | `#7A4600` |
| S3 | 24 hours (1440) | 36 hours (2160) | Minor Issue | `#005FB2` |

Targets are stored in **minutes**. To change a target, edit the record (e.g. `S1_First_Response` → Target Minutes).

### Priority → Severity (`SLT_Priority_Map__mdt`)

High → S1, Medium → S2, Low → S3 (Low is the default for blank or unmapped Priority).

### Thresholds and options (`SLT_Setting__mdt` → `Default`)

| Setting | Default |
|---|---|
| Red Threshold Minutes | 60 |
| Amber Threshold Percent | 40 |
| Use Case Milestones | on |
| Max Rows | 1000 (effective maximum 1,500) |

### Business hours

Tick **Use Business Hours** on a rule; leave **Business Hours Name** blank for the org default or enter another Business Hours record's name.

### Adding P1–P4 severities

Add the values to the Case **Severity** picklist, create `SLT_Rule__mdt` records for each severity × phase, and repoint `SLT_Priority_Map__mdt`. Step by step: [DOCUMENTATION.md §5](./DOCUMENTATION.md#adding-p1p4-style-severities).

---

## 6. Automation

| Component | When | What |
|---|---|---|
| `SLTCaseTrigger` (before insert on Case) | New case with blank Severity | Sets `Severity__c` from Priority using `SLT_Priority_Map__mdt`; only writes values present in the Severity picklist; a manually set Severity is kept |
| `SLTEmailMessageTrigger` (after insert on EmailMessage) | Outbound email on a case | Stamps `First_Response_Date__c` (first time) and `Last_Update_Date__c` (always) |

The original version's two Flows, four formula fields and `Milestone_Type__c` have been removed. Orgs that still have them: see [SETUP.md](./SETUP.md#upgrading-an-org-that-ran-the-original-version).

---

## 7. Apex

| Class | Purpose |
|---|---|
| `SLTRuleService` | SLT engine; loads configuration once per transaction; `evaluate()` (exact) and `estimate()` (calendar time, for ranking) |
| `SLTDashboardController` | `getActiveCases(ownerId, queueId)` — scope resolution, two-stage ranking, `DashboardResult` / `CaseRow` |
| `SLTCaseTriggerHandler` | Severity stamping for `SLTCaseTrigger` |
| `SLTTestFactory` | Test-only in-memory configuration |

Test classes: `SLTRuleServiceTest`, `SLTDashboardControllerTest`, `SLTCaseTriggerHandlerTest`, `SLTEmailMessageTriggerTest`. Tests inject configuration and never depend on which metadata records exist in the org.

---

## 8. LWC dashboard component

**Files:** `force-app/main/default/lwc/sfSltDashboard/`

| Property | Purpose |
|---|---|
| `ownerId` | Pin the dashboard to one user's cases |
| `queueId` | Include a queue's open cases |

- **Refresh / countdown** — server refresh every 30 s; calendar-time rows tick every 1 s. Business-hours rows update on refresh only (their clock may be paused).
- **Sorting** — click a header; RAG sorts Red → Amber → Green; nulls last.
- **Progress bar** — elapsed ÷ window, capped at 100%, fixed green → orange → red gradient.
- **Truncation note** — "Showing the most urgent X of Y open cases" when rows are cut.

| What | Where |
|---|---|
| Refresh interval | `REFRESH_INTERVAL_MS` in `sfSltDashboard.js` |
| Countdown interval | `TICK_INTERVAL_MS` |
| RAG badge labels | `RAG_LABEL`, `NO_RULE_LABEL` |
| Default column visibility | `DEFAULT_COLUMNS` |
| Progress bar gradient | `.progress-fill` in `sfSltDashboard.css` |

---

## 9. Permission sets

| Permission Set | Purpose |
|---|---|
| `SLTDashboardAccess` | **Required for every user.** Read access to SLT Case fields + Apex class access |
| `SLTScope_All` / `SLTScope_Org` / `SLTScope_Team` / `SLTScope_Own` | One per user — Director / Manager / Technical Lead / Agent scope |

Admins editing SLT configuration need **Customize Application**. Assignment instructions: [SETUP.md](./SETUP.md).

---

## 10. Limits

- Up to **10,000** open cases in scope are ranked per refresh (oldest first by created date). Beyond that, newer cases are not ranked and the dashboard shows "… of 10000+ open cases".
- **Max Rows is effectively capped at 1,500**: only the 1,500 most urgent candidates get the exact (business-hours) calculation.
- Measured worst case (every rule on business hours, 10,000 cases): ≈ 4 s of the 10 s Apex CPU limit.

Details: [DOCUMENTATION.md §11](./DOCUMENTATION.md#11-limits-and-performance).

---

## 11. Deploy and setup

Step-by-step instructions: **[SETUP.md](./SETUP.md)**.

```bash
# Deploy everything
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS

# Run the SLT tests
sf apex run test \
  --class-names SLTRuleServiceTest --class-names SLTDashboardControllerTest \
  --class-names SLTCaseTriggerHandlerTest --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS --wait 20 --code-coverage --result-format human
```

---

## 12. Configuration reference

| What to change | Where |
|---|---|
| SLT target for a severity and phase | Setup → Custom Metadata Types → SLT Rule → record → Target Minutes |
| Business hours for a rule | SLT Rule → Use Business Hours / Business Hours Name |
| Severity pill colour / label / order | SLT Rule → Severity Color / Severity Label / Sort Order |
| Priority → Severity mapping | SLT Priority Map records |
| Red threshold (minutes) | SLT Setting → Default → Red Threshold Minutes |
| Amber threshold (% remaining) | SLT Setting → Default → Amber Threshold Percent |
| Use Case Milestones on/off | SLT Setting → Default → Use Case Milestones |
| Rows returned | SLT Setting → Default → Max Rows (≤ 1,500) |
| Scope label text / translations | Setup → Custom Labels → `SLT_Scope_Label_*` |
| Pin dashboard to a user / add a queue | Lightning App Builder → component properties |
| Refresh rate, badge text, default columns, gradient | `sfSltDashboard.js` / `.css` (code) |

---

## 13. Edge cases

- **Cases created before deployment** — Severity is resolved live from Priority; run the backfill in SETUP.md to store it.
- **Blank or unmapped Priority** — uses the default priority mapping (S3 by default).
- **Severity with no rule** — grey "No SLT rule" badge, excluded from RAG counts, listed last.
- **No Case Milestones** — SLT rules apply to every case; Target Date and Completion Date show `—`.
- **Inbound-only cases** — stay in the First Response phase.
- **Dashboard error after deploying a new version** — clear the browser cache (see SETUP.md).
- **Multiple scope sets** — highest scope wins.

---

## 14. Custom Metadata Created (Summary)

| Kind | Items |
|---|---|
| Custom Metadata Types (3) | `SLT_Rule__mdt` (6 records), `SLT_Priority_Map__mdt` (3), `SLT_Setting__mdt` (1: Default) |
| Case fields (3) | `Severity__c`, `First_Response_Date__c`, `Last_Update_Date__c` |
| Apex classes (8) | `SLTRuleService`, `SLTDashboardController`, `SLTCaseTriggerHandler`, `SLTTestFactory` + 4 test classes |
| Apex triggers (2) | `SLTCaseTrigger`, `SLTEmailMessageTrigger` |
| Custom Labels (5) | `SLT_Scope_Label_Filtered`, `_All`, `_Org`, `_Team`, `_Own` |
| Custom Permissions (4) | `SLT_Scope_All`, `SLT_Scope_Org`, `SLT_Scope_Team`, `SLT_Scope_Own` |
| Permission Sets (5) | `SLTDashboardAccess`, `SLTScope_All`, `SLTScope_Org`, `SLTScope_Team`, `SLTScope_Own` |
| LWC (1) | `sfSltDashboard` |

`CaseMilestone` and `BusinessHours` are standard Salesforce objects, used but not created by this project.
