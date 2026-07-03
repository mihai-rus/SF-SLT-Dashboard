# SF SLT Dashboard

### Technical Documentation

---

## 1. Product Overview

### What it is

The SF SLT Dashboard is a Salesforce Lightning Web Component (LWC) that gives support agents, technical leads, managers, and directors a live **Red / Amber / Green (RAG)** view of every open Case's Service Level Target (SLT) compliance. Each user sees only the cases relevant to their assigned scope, and the dashboard auto-refreshes every 30 seconds with no manual page reload.

> **RAG** here means Red / Amber / Green — a traffic-light compliance indicator. It is unrelated to AI or retrieval-augmented generation. This org has a separate, unrelated `RAG_Status__c` field from an AI Case Triage system; this dashboard uses its own `SLT_RAG_Status__c` field.

### Problem it solves

Support teams must respond to and update cases within contractual time windows that vary by severity (e.g. 30 minutes first response for an S1, 4 hours between updates). Without a single live view, teams cannot easily tell which cases are about to breach their SLT, which have already breached, and which are on track. Managers also need a view scoped to their team or organisation rather than the whole org.

### How it solves it

- **Live calculation, no jobs.** All time/risk math (target hours, elapsed time, remaining time, RAG status) is implemented as **Case formula fields** that recompute at query time. There are no scheduled jobs, batch apex, or background processes keeping numbers fresh.
- **Automatic SLT lifecycle.** Two Before-Save record-triggered Flows and one Apex trigger on `EmailMessage` set severity on creation, advance the milestone phase, and stamp response/update timestamps automatically as agents work cases.
- **Role-based scoping.** A single Apex controller method (`SLTDashboardController.getActiveCases`) inspects the running user's Custom Permissions and returns only the cases in scope, along with a human-readable scope label.
- **Self-refreshing UI.** The `sfSltDashboard` LWC polls the controller every 30 seconds and renders summary cards, RAG filters, a column picker, sortable columns, and a gradient progress bar.

### Who it is for

- **Agents** — see only their own cases.
- **Technical Leads** — see cases for agents one level below them in the role hierarchy.
- **Managers** — see cases for the entire role subtree beneath them.
- **Directors** — see all open cases across the org.

---

## 2. Architecture

This is a **pure-Salesforce** solution. There are no external APIs, no middleware, no scheduled jobs, and no AI components. Everything runs on the Salesforce platform.

### High-level flow

```
New Case Created
  └── Flow: Case_Set_SLT_Fields_On_Create  (Before Save, on Create)
        └── Maps Priority → Severity__c and sets Milestone_Type__c = "First Response"

SLT Clock Running  (Case formula fields — recomputed at query time, no code)
  ├── SLT_Target_Hours__c  — target hours for the current phase (by Severity)
  ├── Hours_Elapsed__c     — hours since the current phase started
  ├── Hours_Remaining__c   — SLT_Target_Hours__c − Hours_Elapsed__c (negative = breached)
  └── SLT_RAG_Status__c    — "Red" / "Amber" / "Green"

Agent Sends Outbound Email
  └── Trigger: SLTEmailMessageTrigger  (after insert on EmailMessage)
        ├── First outbound email → stamps First_Response_Date__c + Last_Update_Date__c
        ├── Later outbound emails → stamps only Last_Update_Date__c
        └── Flow: Case_Update_Milestone_On_First_Response  (Before Save, on Update)
              └── Sets Milestone_Type__c → "Update"

Dashboard Loads / Auto-refreshes (every 30 s)
  └── sfSltDashboard LWC → SLTDashboardController.getActiveCases(ownerId)
        ├── ownerId set (App Builder override) → that user's cases  → "Filtered View"
        ├── SLT_Scope_All  → all open cases                         → "All Cases"
        ├── SLT_Scope_Org  → role subtree beneath the user          → "Your Organisation"
        ├── SLT_Scope_Team → users in direct child roles            → "Your Team"
        └── fallback       → the running user's own cases           → "Your Cases"
        Returns DashboardResult { cases: List<CaseRow>, scopeLabel: String }
```

### Data flow, step by step

1. A Case is created. The Before-Save flow `Case_Set_SLT_Fields_On_Create` runs in the same transaction (no extra DML) and, only if `Severity__c` is blank, maps `Priority` to `Severity__c` (High→S1, Medium→S2, Low/blank→S3) and sets `Milestone_Type__c = "First Response"`.
2. From that moment the SLT formula fields compute against `CreatedDate`. The case begins counting toward its **first response** target.
3. When the agent sends the first outbound email from the case, `SLTEmailMessageTrigger` fires on `EmailMessage` insert. It stamps both `First_Response_Date__c` and `Last_Update_Date__c` with the current time.
4. Because `First_Response_Date__c` is now populated, `Hours_Elapsed__c` switches to counting from that timestamp, and `SLT_Target_Hours__c` switches to the larger **update** target. The clock effectively resets and the case enters the update phase. The Before-Save flow `Case_Update_Milestone_On_First_Response` sets `Milestone_Type__c = "Update"`.
5. Each subsequent outbound email re-stamps `Last_Update_Date__c`, resetting the elapsed clock so the agent gets a fresh update window.
6. The LWC calls `getActiveCases` on load and then every 30 seconds. The controller resolves the user's scope, queries open cases (plus their most relevant `CaseMilestone`), wraps them in `CaseRow` objects, and returns them with a `scopeLabel`.
7. The LWC enriches each row (formatting, progress percentage, RAG label/badge classes) and renders the table, summary cards, and filters.

### Sharing and security model

- **Apex sharing.** `SLTDashboardController` is declared `public with sharing`, so SOQL queries respect the running user's record-level access in addition to the explicit `OwnerId` scope filters.
- **Field access.** The `SLTDashboardAccess` permission set grants read-only access to all eight SLT custom fields and execute access to the controller class.
- **Scope enforcement.** Scope is determined by Custom Permissions checked via `FeatureManagement.checkPermission(...)`. Scope assignment is decoupled from the org's role hierarchy (any user can be given any scope), but the `Org` and `Team` scopes traverse the role hierarchy at runtime, so those users must have their Salesforce **Role** set correctly.
- **Multiple scopes.** If a user is accidentally assigned more than one scope set, the highest scope wins, because the controller checks `All → Org → Team → Own` in that order and returns on the first match.

---

## 3. Technology Stack

### Languages and frameworks

| Layer | Technology |
|---|---|
| Frontend | Lightning Web Components (JavaScript ES2020, HTML templates, scoped CSS) |
| Backend | Apex (`SLTDashboardController`), Apex Trigger (`SLTEmailMessageTrigger`) |
| Business rules | Salesforce Flow (Before-Save record-triggered flows) |
| Data / calculations | Case formula fields (Salesforce formula language) |
| Source format / tooling | Salesforce DX (sfdx) source format, Salesforce CLI (`sf`) |
| API version | 59.0 (`sourceApiVersion` in `sfdx-project.json`; same `apiVersion` on the LWC bundle) |

### Salesforce platform features used

- **Lightning Web Components** — exposed to App Page, Home Page, and Record Page (Case and User) targets via the `.js-meta.xml` bundle. Exposes a single `ownerId` String property in Lightning App Builder.
- **Apex with sharing** — `@AuraEnabled(cacheable=true)` entry point for client caching.
- **`FeatureManagement.checkPermission`** — reads the running user's Custom Permissions to resolve scope.
- **Custom Permissions** — `SLT_Scope_All`, `SLT_Scope_Org`, `SLT_Scope_Team`, `SLT_Scope_Own`.
- **Permission Sets** — one base access set plus four scope sets.
- **Record-triggered Flows (Before Save)** — run inside the save transaction with no additional DML.
- **Standard `CaseMilestone` / Entitlement Milestones** — used (when present) for Target Date, Completion Date, and `IsViolated`, with formula-field fallbacks when no milestone record exists.
- **Custom formula fields on Case** — all SLT math.

### AI / external integration details

None. There are no external API callouts, named credentials, integrations, or AI/LLM components anywhere in this project. The "RAG" terminology refers strictly to the Red/Amber/Green traffic-light indicator.

---

## 4. SLT Calculation Engine (Formula Fields)

The core domain logic — how much time a case has, how much it has used, and whether it is at risk — is implemented entirely as **Case formula fields**, evaluated live at query time. No Apex or scheduled process maintains these values.

### `Severity__c` and `Milestone_Type__c` (inputs)

- `Severity__c` (Picklist): `S1`, `S2`, `S3` — set on creation by the flow from `Priority`.
- `Milestone_Type__c` (Picklist): `First Response`, `Update`, `Resolution` — display/phase indicator.
- `First_Response_Date__c` (DateTime): timestamp of the first outbound email.
- `Last_Update_Date__c` (DateTime): timestamp of the most recent outbound email.

### `SLT_Target_Hours__c` (Formula, Number)

Returns the target hours for the **current phase**, keyed off whether a first response has been sent and the case's severity:

```
IF(ISBLANK(First_Response_Date__c),                 // before first response
   IF(S1, 0.5, IF(S2, 2, IF(S3, 24, 0))),
   IF(S1, 4,   IF(S2, 24, IF(S3, 36, 0))))          // after first response
```

| Severity | First Response target | Update target |
|---|---|---|
| S1 — Production Down | 0.5 h (30 min) | 4 h |
| S2 — Production Impaired | 2 h | 24 h |
| S3 — Minor Issue | 24 h | 36 h |

### `Hours_Elapsed__c` (Formula, Number)

Hours since the current phase started, computed by multiplying the day-based date difference by 24:

```
No first response yet:        (NOW() − CreatedDate) * 24
First response, no update:    (NOW() − First_Response_Date__c) * 24
Update sent:                  (NOW() − Last_Update_Date__c) * 24
```

### `Hours_Remaining__c` (Formula, Number)

```
SLT_Target_Hours__c − Hours_Elapsed__c        // negative = breached
```

### `SLT_RAG_Status__c` (Formula, Text)

```
Hours_Remaining__c <= 0                            → "Red"   (breached)
Hours_Remaining__c < 1                             → "Red"   (< 1 hour left)
Hours_Remaining__c < (SLT_Target_Hours__c * 0.4)   → "Amber" (< 40% of window left)
otherwise                                          → "Green"
```

All four formula fields are `Number(10,2)` / `Text` and use `formulaTreatBlanksAs = BlankAsZero`.

### Where the LWC complements the formulas

The LWC derives a couple of presentation values that are not stored:

- **Progress percentage** = `min(round((hoursElapsed / sltTargetHours) * 100), 100)`, falling back to 100 if the case is breached and the target is zero.
- **Time remaining display** = formatted from `timeRemainingMins` as `Xh Ym` (or `-Xh Ym`, shown in red, when breached).
- **RAG labels** = `Red→"Critical"`, `Amber→"At risk"`, `Green→"On track"`.

### Changing the thresholds

- Edit `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` to change target hours (all values in hours; `0.5` = 30 min). First block = first-response targets, second block = update targets.
- Edit `objects/Case/fields/SLT_RAG_Status__c.field-meta.xml` to change the Red absolute threshold (`1` hour) or the Amber percentage threshold (`0.4` = 40%).
- Redeploy the single changed field with `sf project deploy start --source-dir <field> --target-org <alias>`.

---

## 5. File Structure

```
SLT_Dashboard_v1/
├── README.md                          # Functional overview and configuration reference
├── SETUP.md                           # Step-by-step deploy and org-configuration guide
├── DOCUMENTATION.md                   # This technical documentation
├── sfdx-project.json                  # SFDX project config; sourceApiVersion 59.0, default package "force-app"
├── config/
│   └── project-scratch-def.json       # Scratch org definition (Developer edition, "SLT RAG Dashboard Dev")
└── force-app/main/default/
    ├── classes/
    │   ├── SLTDashboardController.cls          # Apex controller: scope resolution + case/milestone queries
    │   ├── SLTDashboardControllerTest.cls      # Tests for the controller
    │   ├── SLTEmailMessageTriggerTest.cls      # Tests for the email trigger
    │   └── *.cls-meta.xml                       # Apex metadata files
    ├── triggers/
    │   ├── SLTEmailMessageTrigger.trigger      # After-insert on EmailMessage; stamps response/update dates
    │   └── SLTEmailMessageTrigger.trigger-meta.xml
    ├── flows/
    │   ├── Case_Set_SLT_Fields_On_Create.flow-meta.xml          # Before-Save on Create: Priority→Severity, set First Response
    │   └── Case_Update_Milestone_On_First_Response.flow-meta.xml # Before-Save on Update: Milestone_Type__c → Update
    ├── objects/Case/fields/
    │   ├── Severity__c.field-meta.xml           # Picklist: S1/S2/S3
    │   ├── Milestone_Type__c.field-meta.xml     # Picklist: First Response/Update/Resolution
    │   ├── First_Response_Date__c.field-meta.xml# DateTime: first outbound email
    │   ├── Last_Update_Date__c.field-meta.xml   # DateTime: most recent outbound email
    │   ├── SLT_Target_Hours__c.field-meta.xml   # Formula(Number): phase target hours by severity
    │   ├── Hours_Elapsed__c.field-meta.xml      # Formula(Number): hours since current phase start
    │   ├── Hours_Remaining__c.field-meta.xml    # Formula(Number): target − elapsed
    │   └── SLT_RAG_Status__c.field-meta.xml     # Formula(Text): Red/Amber/Green
    ├── customPermissions/
    │   ├── SLT_Scope_All.customPermission-meta.xml   # Director scope flag
    │   ├── SLT_Scope_Org.customPermission-meta.xml   # Manager scope flag
    │   ├── SLT_Scope_Team.customPermission-meta.xml  # Technical Lead scope flag
    │   └── SLT_Scope_Own.customPermission-meta.xml   # Agent scope flag
    ├── permissionsets/
    │   ├── SLTDashboardAccess.permissionset-meta.xml # Base access: 8 fields + controller
    │   ├── SLTScope_All.permissionset-meta.xml       # "SLT Dashboard - Director Scope"
    │   ├── SLTScope_Org.permissionset-meta.xml       # "SLT Dashboard - Manager Scope"
    │   ├── SLTScope_Team.permissionset-meta.xml      # "SLT Dashboard - Technical Lead Scope"
    │   └── SLTScope_Own.permissionset-meta.xml       # "SLT Dashboard - Agent Scope"
    └── lwc/sfSltDashboard/
        ├── sfSltDashboard.js          # Component logic: load loop, enrichment, sort/filter/columns
        ├── sfSltDashboard.html        # Table, summary cards, RAG filters, column picker, progress bar
        ├── sfSltDashboard.css         # Styling incl. progress-bar gradient and RAG/severity badges
        └── sfSltDashboard.js-meta.xml # Exposes component; AppPage/HomePage/RecordPage targets; ownerId property
```

### Key implementation notes

- **`SLTDashboardController.cls`** — Public types `DashboardResult` and `CaseRow`. Entry point `getActiveCases(String ownerId)` is `@AuraEnabled(cacheable=true)`. Role-hierarchy helpers (`getUsersInSubtree`, `getUsersInDirectSubroles`, `buildRoleChildMap`, `getDescendantRoleIds`, `getUsersInRoles`) resolve subordinate user IDs. Queries exclude closed cases, sub-query the most relevant `CaseMilestone` (`ORDER BY TargetDate ASC NULLS LAST LIMIT 1`), order by `Hours_Remaining__c ASC NULLS LAST`, and cap at 1000 rows. `buildRows` falls back to custom fields when no milestone exists.
- **`SLTEmailMessageTrigger.trigger`** — After-insert on `EmailMessage`. Filters to outbound (`!Incoming`) emails whose `ParentId` is a Case (`500` key prefix), then stamps `Last_Update_Date__c` (always) and `First_Response_Date__c` (only when null).
- **`sfSltDashboard.js`** — Tunable constants at the top: `REFRESH_INTERVAL_MS` (30000), `RAG_LABEL`, `RAG_ORDER`, `DEFAULT_COLUMNS` (12 columns), `SORT_PROP`. Polls via `setInterval` in `connectedCallback` and clears it in `disconnectedCallback`. Client-side filtering by RAG, sorting (RAG sorts Red→Amber→Green, nulls to bottom), and per-column show/hide.

---

## 6. Prerequisites

- **Salesforce CLI** (`sf`) — [developer.salesforce.com/tools/salesforcecli](https://developer.salesforce.com/tools/salesforcecli)
- **Node.js** — required by the Salesforce CLI
- **Git**
- A target Salesforce org you can authenticate to (the project targets API version 59.0)
- If using Manager (`SLT_Scope_Org`) or Technical Lead (`SLT_Scope_Team`) scopes: a configured **Role hierarchy** in the org

---

## 7. Installation and Setup

### Part 1 — Terminal

**1. Clone the repository**

```bash
git clone https://github.com/mihai-rus/SF-SLT-Dashboard.git
cd SF-SLT-Dashboard
```

**2. Authenticate with your org**

```bash
sf org login web --alias YOUR_ORG_ALIAS
sf org display --target-org YOUR_ORG_ALIAS   # verify
```

**3. Deploy all metadata**

```bash
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

This deploys the custom/formula fields, both flows, the Apex trigger and controller, the LWC, the base access permission set, the four scope permission sets, and the four custom permissions in one command.

**4. Run the tests**

```bash
sf apex run test \
  --class-names SLTDashboardControllerTest \
  --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS --wait 10 --result-format human
```

All tests should pass before proceeding.

**5. Backfill Severity on pre-existing open cases (if needed)**

Cases created before deployment have no `Severity__c` and would show Red immediately. The executing user must have `SLTDashboardAccess` first:

```bash
sf org assign permset --name SLTDashboardAccess --target-org YOUR_ORG_ALIAS
```

Then run this in **Developer Console → Execute Anonymous**:

```apex
List<Case> cases = [SELECT Id, Priority, Severity__c FROM Case
                    WHERE Status != 'Closed' AND Severity__c = null];
for (Case c : cases) {
    if      (c.Priority == 'High')   c.Severity__c = 'S1';
    else if (c.Priority == 'Medium') c.Severity__c = 'S2';
    else                             c.Severity__c = 'S3';
}
update cases;
```

### Part 2 — Salesforce setup

1. **Activate the flows** — Setup → Flows → confirm **Case – Set SLT Fields On Create** and **Case – Switch Milestone to Update on First Response** are **Active** (both ship as Active; activate manually if not).
2. **Verify the trigger** — Setup → Apex Triggers → confirm `SLTEmailMessageTrigger` is Active.
3. **Create the Lightning page** — Setup → Lightning App Builder → New → App Page → One Region → drag **sfSltDashboard** onto the canvas → (optional) set **Filter by Owner ID** to pin to one user → Save → Activate (Org Default, Desktop).
4. **Add it to navigation** — Setup → App Manager → edit your support app → Navigation Items → add the new page → Save.
5. **Assign permissions** — every user needs **two** sets: `SLTDashboardAccess` plus exactly one scope set (see Access Control below). UI: Setup → Users → user → Permission Set Assignments → Edit Assignments. CLI example:
   ```bash
   sf org assign permset --name SLTDashboardAccess --name SLTScope_Team \
     --on-behalf-of lead@yourorg.com --target-org YOUR_ORG_ALIAS
   ```
6. **Configure roles** (for Manager/TL scopes) — set each relevant user's **Role** (Setup → Users → Edit) so the hierarchy lookup works. The structure itself lives under Setup → Roles. No specific role names are required; the controller traverses whatever parent/child structure exists.
7. **(Optional) Add SLT fields to the Case page layout** — `Severity__c`, `Milestone_Type__c`, `First_Response_Date__c`, `Last_Update_Date__c`, `Hours_Remaining__c`, `SLT_RAG_Status__c`.

### Part 3 — After deploying updates

- **Clear the LWC cache after a component redeploy.** Salesforce caches the compiled LWC JS in the browser. If the dashboard errors after a fresh deploy: DevTools → Application → Storage → Clear site data, then reload; or run `localStorage.clear(); sessionStorage.clear();` in the console; or test in an incognito window.
- **Redeploy only what changed** — e.g. LWC only:
  ```bash
  sf project deploy start --source-dir force-app/main/default/lwc/sfSltDashboard --target-org YOUR_ORG_ALIAS
  ```

---

## 8. SLT Lifecycle (Automation Detail)

### Phase 1 — Waiting for first response
On creation, the clock starts from `CreatedDate` against the first-response target for the case's severity. No manual action required.

### Phase 2 — First response given
The first outbound email triggers `SLTEmailMessageTrigger`, which stamps `First_Response_Date__c` and `Last_Update_Date__c`. `SLT_Target_Hours__c` switches to the larger update target, `Hours_Elapsed__c` recounts from the first-response timestamp (effective reset), and the milestone flips to "Update".

### Phase 3 — Ongoing updates
Each subsequent outbound email re-stamps `Last_Update_Date__c`, resetting the elapsed clock for another full update window.

### What does and does not trigger a reset
The reset is driven by Salesforce-originated **outbound** `EmailMessage` records. Inbound emails and emails sent from external clients (Outlook, Gmail, etc.) do not create an outbound `EmailMessage` and will not reset the timer.

### Automation components

| Component | Type | When it runs | What it does |
|---|---|---|---|
| `Case_Set_SLT_Fields_On_Create` | Flow, Before Save (Create) | New Case, only if `Severity__c` blank | Maps Priority→Severity (High→S1, Medium→S2, Low/blank→S3); sets `Milestone_Type__c="First Response"` |
| `Case_Update_Milestone_On_First_Response` | Flow, Before Save (Update) | Case update where `First_Response_Date__c` is set | Sets `Milestone_Type__c="Update"` |
| `SLTEmailMessageTrigger` | Apex trigger, after insert | Outbound EmailMessage with Case parent | Stamps `Last_Update_Date__c` (always) and `First_Response_Date__c` (first time only) |

---

## 9. Access Control

### Two permission sets per user

| Set | API name | Grants |
|---|---|---|
| Base access (required) | `SLTDashboardAccess` | Read on the 8 SLT Case fields + execute on `SLTDashboardController` |
| One scope set (required) | one of the four below | How much data the user sees |

- Base access **without** a scope set → user sees only their own cases (safe default).
- A scope set **without** base access → dashboard throws an error (no field/class access).

### Scope sets and custom permissions

| Permission Set (API) | Label | Custom Permission | Cases shown | Scope label |
|---|---|---|---|---|
| `SLTScope_All` | SLT Dashboard - Director Scope | `SLT_Scope_All` | All open cases | All Cases |
| `SLTScope_Org` | SLT Dashboard - Manager Scope | `SLT_Scope_Org` | Role subtree beneath the user | Your Organisation |
| `SLTScope_Team` | SLT Dashboard - Technical Lead Scope | `SLT_Scope_Team` | Users in direct child roles | Your Team |
| `SLTScope_Own` | SLT Dashboard - Agent Scope | `SLT_Scope_Own` | The user's own cases | Your Cases |

The controller resolves scope by checking `FeatureManagement.checkPermission('SLT_Scope_All' → 'SLT_Scope_Org' → 'SLT_Scope_Team')`, falling back to own-cases. First match wins, so the **highest** scope applies if multiple are assigned. Audit via Setup → Permission Sets → Manage Assignments.

### Admin override

Setting the LWC's `ownerId` property in Lightning App Builder pins the dashboard to a single user's cases for everyone who views that page, regardless of their scope permission. The header then reads "Viewing: Filtered View".

---

## 10. Edge Cases

- **Pre-deployment cases** — no `Severity__c`, so they appear Red until backfilled (see step 5 above).
- **Blank Priority** — the flow maps blank Priority to S3; the case still gets a valid target.
- **No CaseMilestone record** — if Entitlement Milestones are not used, Target Date and Completion Date show `—`, and `isViolated` is derived from `Hours_Remaining__c <= 0`; all other columns work normally.
- **Inbound-only cases** — if no outbound email is ever sent, the trigger never fires and the case stays in Phase 1, counting from creation against the first-response target.
- **Stale browser cache** — after a new LWC deploy, clear site data / use incognito (see Part 3).
- **Separate `RAG_Status__c` field** — this dashboard uses `SLT_RAG_Status__c` only; the unrelated AI Case Triage `RAG_Status__c` field coexists independently.
