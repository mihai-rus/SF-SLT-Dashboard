# SF SLT Dashboard — Salesforce LWC

A Lightning Web Component that gives support agents and managers a live **Red / Amber / Green** view of every open case's SLT compliance. Each user sees only the cases relevant to their assigned scope permission. The dashboard auto-refreshes every 30 seconds and requires no manual page refresh.

> **RAG** here means Red / Amber / Green — a traffic-light compliance indicator. It has nothing to do with AI or retrieval-augmented generation.

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [Role-based scoping](#2-role-based-scoping)
3. [How SLT tracking works — the full lifecycle](#3-how-slt-tracking-works--the-full-lifecycle)
4. [Tech stack and architecture](#4-tech-stack-and-architecture)
5. [Custom fields on Case](#5-custom-fields-on-case)
6. [SLT values — and how to change them](#6-slt-values--and-how-to-change-them)
7. [Automation flows](#7-automation-flows)
8. [Email trigger](#8-email-trigger)
9. [Apex controller](#9-apex-controller)
10. [LWC dashboard component](#10-lwc-dashboard-component)
11. [Permission sets](#11-permission-sets)
12. [Deploy and setup](#12-deploy-and-setup)
13. [Configuration reference](#13-configuration-reference)
14. [Edge cases](#14-edge-cases)

---

## 1. What it does

| Feature | Detail |
|---|---|
| Role-based scope | Each user automatically sees the right cases for their role — Agent, Technical Lead, Manager, or Director |
| Scope label | Header shows "Viewing: Your Team" / "Your Organisation" / "All Cases" etc. so it is always clear what is displayed |
| Live case table | All relevant open cases, sortable by any column |
| 12 available columns | Case #, Subject, Owner, Status, Severity, Milestone Name, Target Date, Time Remaining, Progress, Violated, Completion Date, RAG Status |
| Column picker | Show or hide any column via the Columns button — takes effect immediately |
| Sortable columns | Click any column header to sort ascending; click again for descending |
| Summary cards | Counts of Total / Critical / At Risk / On Track cases (scoped to what the user can see) |
| RAG filter buttons | Filter the table to show only Critical, At Risk, or On Track cases |
| Gradient progress bar | Fill bar transitions green → orange → red as the SLT deadline approaches |
| Time remaining | Displays `Xh Ym`, or `-Xh Ym` in red when breached |
| Violated indicator | Yes / No badge showing whether the SLT has been breached |
| Target Date | Milestone target date/time from the CaseMilestone record |
| Completion Date | Milestone completion date from the CaseMilestone record |
| Auto-refresh | Reloads data every 30 seconds — no page refresh needed |
| Automatic SLT reset | Timer resets when an outbound email is sent from the case |
| Priority mapping | New cases get Severity auto-populated from the Case Priority field |

### Available columns

| Column | Source |
|---|---|
| Case # | `Case.CaseNumber` |
| Subject | `Case.Subject` |
| Owner | `Case.Owner.Name` |
| Status | `Case.Status` |
| Severity | `Case.Severity__c` |
| Milestone Name | `CaseMilestone.MilestoneType.Name` (falls back to `Case.Milestone_Type__c`) |
| Target Date | `CaseMilestone.TargetDate` |
| Time Remaining | Calculated from `CaseMilestone.TargetDate − now()`, or `Hours_Remaining__c × 60` |
| Progress | `(Hours_Elapsed__c / SLT_Target_Hours__c) × 100%` |
| Violated | `CaseMilestone.IsViolated` (falls back to `Hours_Remaining__c ≤ 0`) |
| Completion Date | `CaseMilestone.CompletionDate` |
| RAG Status | `Case.SLT_RAG_Status__c` |

---

## 2. Role-based scoping

The dashboard automatically adjusts what each user sees based on a Salesforce Custom Permission assigned to them. The scope **assignment** is decoupled from the org's role hierarchy — any user can be assigned any scope regardless of their position in the org chart. However, the `Manager` and `Technical Lead` scopes still traverse the role hierarchy at runtime to find subordinate users, so those users must have their Salesforce Role set correctly.

### Scope levels

| Scope | Permission Set to assign | What the user sees |
|---|---|---|
| Director | `SLT Dashboard - Director Scope` | All open cases in the entire org |
| Manager | `SLT Dashboard - Manager Scope` | All cases for every user and team beneath them in the role hierarchy |
| Technical Lead | `SLT Dashboard - Technical Lead Scope` | Cases for all agents in their direct team (one level down in the role hierarchy) |
| Agent | `SLT Dashboard - Agent Scope` | Only their own cases |
| *(no scope assigned)* | — | Only their own cases (same as Agent — safe default) |

### How scope is determined

When the dashboard loads it checks the logged-in user's Custom Permissions in this priority order:

1. `SLT_Scope_All` → show all cases (Director)
2. `SLT_Scope_Org` → traverse the role hierarchy and show all cases for every user beneath (Manager)
3. `SLT_Scope_Team` → show cases for users in direct child roles only (Technical Lead)
4. Fallback → show own cases only (Agent or no permission)

The scope label displayed in the dashboard header ("Viewing: Your Team" etc.) reflects the active scope.

### Two permission sets are required per user

Every user needs:
1. **`SLT Dashboard Access`** — grants access to the Apex controller and all SLT fields on Case
2. **One scope set** — controls how much data they see

Missing either one causes an error or wrong behaviour. See [SETUP.md](./SETUP.md) for full assignment instructions.

### Admin override

Setting the `ownerId` property on the component in Lightning App Builder pins the dashboard to a specific user's cases for everyone who views that page, regardless of their scope permission. The header shows "Viewing: Filtered View" when this override is active.

---

## 3. How SLT tracking works — the full lifecycle

### Phase 1 — Waiting for first response

When a case is created, the SLT clock starts immediately from the creation timestamp. The target is the **first response SLT** for the case's severity (e.g. 30 minutes for S1). Nothing needs to happen manually.

### Phase 2 — First response given

When an agent **sends an outbound email** from the case, the system automatically:

1. Records the timestamp as `First_Response_Date__c` (first outbound email only)
2. Records the same timestamp as `Last_Update_Date__c`
3. The SLT target switches to the **update SLT** (e.g. 4 hours for S1)
4. The elapsed clock resets to zero — the agent now has the full update window
5. The Milestone field on the case flips from "First Response" to "Update"

### Phase 3 — Ongoing updates

Every subsequent outbound email updates `Last_Update_Date__c` to the current time. The elapsed clock resets again, giving the agent another full update window.

### What triggers the reset

The reset is driven by the **Salesforce EmailMessage trigger** — it fires whenever an outbound email is sent through Salesforce. Emails sent from an external client (Outlook, Gmail, etc.) do not create an `EmailMessage` record and will not reset the timer.

### Visual representation

The progress bar fill grows left to right as time is consumed, using a continuous gradient:

- **Green** — early on, plenty of time remaining
- **Orange** — deadline approaching
- **Red** — at or past the SLT deadline

The RAG badge reflects the current risk level:

- **Green / On track** — more than 40% of the SLT window remains
- **Amber / At risk** — less than 40% of the window remains
- **Red / Critical** — less than 1 hour remains, or the SLT has already been breached

---

## 4. Tech stack and architecture

This is a **pure Salesforce** solution — no external APIs, no scheduled jobs, no middleware.

| Layer | Technology | Purpose |
|---|---|---|
| Data | Formula fields on Case | All RAG calculations, recalculated live at query time |
| Data | Salesforce CaseMilestone (standard) | Target Date, Completion Date, IsViolated |
| Automation | Record-Triggered Flows (Before Save) | Set Severity on case creation, flip Milestone on first response |
| Automation | Apex Trigger on EmailMessage | Stamp response/update timestamps when emails are sent |
| Backend | Apex class (`SLTDashboardController`) | Query case + milestone data; apply scope filter based on permissions |
| Access — data | Permission Set `SLTDashboardAccess` | Read access to SLT fields and the Apex controller |
| Access — scope | Custom Permissions + 4 scope permission sets | Determine how much data each user sees |
| Frontend | LWC (`sfSltDashboard`) | The dashboard UI, auto-refreshes every 30 s |

### Architecture diagram

```
New Case Created
  └── Flow: Case_Set_SLT_Fields_On_Create
        └── Sets Severity__c (from Priority) and Milestone_Type__c = "First Response"

SLT Clock Running (formula fields — no code needed)
  ├── SLT_Target_Hours__c   — target hours for the current phase
  ├── Hours_Elapsed__c      — hours since the current phase started
  ├── Hours_Remaining__c    — target minus elapsed (negative = breached)
  └── SLT_RAG_Status__c     — "Green" / "Amber" / "Red"

Agent Sends Outbound Email
  └── Trigger: SLTEmailMessageTrigger
        ├── First email → stamps First_Response_Date__c + Last_Update_Date__c
        ├── Subsequent emails → stamps only Last_Update_Date__c
        └── Flow: Case_Update_Milestone_On_First_Response
              └── Flips Milestone_Type__c "First Response" → "Update"

Dashboard Loads (every 30 s)
  └── sfSltDashboard LWC calls SLTDashboardController.getActiveCases()
        ├── Checks Custom Permissions on the logged-in user
        │     SLT_Scope_All   → query all cases (Director)
        │     SLT_Scope_Org   → traverse role hierarchy → query subordinates (Manager)
        │     SLT_Scope_Team  → query direct child role users (Technical Lead)
        │     fallback        → query own cases only (Agent)
        └── Returns DashboardResult { cases: List<CaseRow>, scopeLabel: String }
```

---

## 5. Custom fields on Case

Two fields use the `SLT_` prefix (`SLT_Target_Hours__c`, `SLT_RAG_Status__c`). The remaining six use plain names. This org also has a separate `RAG_Status__c` field from an unrelated AI Case Triage project — do not confuse the two. This dashboard uses `SLT_RAG_Status__c`.

| Field API name | Type | Purpose |
|---|---|---|
| `Severity__c` | Picklist | Case severity: S1, S2, or S3 |
| `Milestone_Type__c` | Picklist | Current SLT phase: First Response, Update, or Resolution |
| `First_Response_Date__c` | DateTime | Timestamp of the first outbound email from this case |
| `Last_Update_Date__c` | DateTime | Timestamp of the most recent outbound email from this case |
| `SLT_Target_Hours__c` | Formula (Number) | Target hours for the current phase, based on Severity |
| `Hours_Elapsed__c` | Formula (Number) | Hours elapsed since the current phase started |
| `Hours_Remaining__c` | Formula (Number) | Target minus elapsed — negative = breached |
| `SLT_RAG_Status__c` | Formula (Text) | "Red", "Amber", or "Green" |

### Formula field logic

**`SLT_Target_Hours__c`:**
```
Before first response:   S1 → 0.5 h  |  S2 → 2 h  |  S3 → 24 h
After first response:    S1 → 4 h    |  S2 → 24 h  |  S3 → 36 h
```

**`Hours_Elapsed__c`:**
```
No first response yet:   NOW() − CreatedDate
First response, no update: NOW() − First_Response_Date__c
Update sent:             NOW() − Last_Update_Date__c
```

**`SLT_RAG_Status__c`:**
```
Hours_Remaining__c ≤ 0                            → Red   (breached)
Hours_Remaining__c < 1                            → Red   (< 1 hour left)
Hours_Remaining__c < (SLT_Target_Hours__c × 0.4) → Amber (< 40% remaining)
Otherwise                                         → Green
```

---

## 6. SLT values — and how to change them

### Current thresholds

| Severity | First Response target | Update target |
|---|---|---|
| S1 — Production Down | 30 minutes (0.5 h) | 4 hours |
| S2 — Production Impaired | 2 hours | 24 hours |
| S3 — Minor Issue | 24 hours | 36 hours |

### To change SLT target hours

Edit `force-app/main/default/objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` and update the numbers in the `<formula>` block. All values are in hours (`0.5` = 30 minutes). Redeploy the single field after saving:

```bash
sf project deploy start \
  --source-dir force-app/main/default/objects/Case/fields/SLT_Target_Hours__c.field-meta.xml \
  --target-org YOUR_ORG_ALIAS
```

### To change when Amber and Red kick in

Edit `force-app/main/default/objects/Case/fields/SLT_RAG_Status__c.field-meta.xml`:
- Change `1` to adjust the absolute Red threshold (currently: go Red when less than 1 hour left)
- Change `0.4` to adjust the Amber percentage threshold (`0.4` = 40%, `0.25` = 25%)

---

## 7. Automation flows

Both flows are **Before Save** record-triggered flows — they run as part of the save transaction with no extra DML.

### `Case_Set_SLT_Fields_On_Create`

Runs on every new Case creation (only if `Severity__c` is not already set). Maps `Priority` → `Severity__c` and sets `Milestone_Type__c = "First Response"`.

| Priority | Severity set |
|---|---|
| High | S1 |
| Medium | S2 |
| Low (or blank) | S3 |

To change the mapping, edit the `<rules>` elements in `force-app/main/default/flows/Case_Set_SLT_Fields_On_Create.flow-meta.xml`.

### `Case_Update_Milestone_On_First_Response`

Runs on every Case update where `First_Response_Date__c` is not blank. Sets `Milestone_Type__c = "Update"` — a display-only change to keep the Milestone column accurate.

---

## 8. Email trigger

**File:** `force-app/main/default/triggers/SLTEmailMessageTrigger.trigger`

Fires after any outbound `EmailMessage` is inserted where the parent is a Case.

- **First outbound email:** stamps both `First_Response_Date__c` and `Last_Update_Date__c`
- **Subsequent outbound emails:** stamps only `Last_Update_Date__c`

Does not fire for inbound emails or for emails sent outside Salesforce.

**Test class:** `SLTEmailMessageTriggerTest.cls`

---

## 9. Apex controller

**File:** `force-app/main/default/classes/SLTDashboardController.cls`

### `getActiveCases(String ownerId)`

Returns a `DashboardResult` object containing:
- `cases` — `List<CaseRow>`, a flat wrapper combining Case + CaseMilestone fields
- `scopeLabel` — a human-readable string ("All Cases", "Your Organisation", "Your Team", "Your Cases", or "Filtered View")

**Scope logic (checked in this exact order — first match wins):**

| Priority | Condition | Cases returned | Scope label |
|---|---|---|---|
| 1 | `ownerId` param set in App Builder | Cases for that specific user only — overrides all permissions | Filtered View |
| 2 | `SLT_Scope_All` permission present | All open cases in the org | All Cases |
| 3 | `SLT_Scope_Org` permission present | Cases for all users in the role subtree beneath the current user | Your Organisation |
| 4 | `SLT_Scope_Team` permission present | Cases for users in direct child roles of the current user's role | Your Team |
| 5 | Fallback (no permission or `SLT_Scope_Own`) | Only the current user's cases | Your Cases |

All queries exclude closed cases, order by `Hours_Remaining__c ASC` (most overdue first), and are capped at 1000 records.

### CaseMilestone fallback

If no `CaseMilestone` record exists for a case, the controller falls back to custom fields:
- `milestoneName` → `Milestone_Type__c`
- `isViolated` → `Hours_Remaining__c ≤ 0`
- `timeRemainingMins` → `Hours_Remaining__c × 60`
- `targetDate` / `completionDate` → null (shown as `—`)

**Test class:** `SLTDashboardControllerTest.cls`

---

## 10. LWC dashboard component

**Files:** `force-app/main/default/lwc/sfSltDashboard/`

### Component property

| Property | Type | Default | Purpose |
|---|---|---|---|
| `ownerId` | String | blank | Admin override — pins the dashboard to one user's cases. Set in Lightning App Builder. Overrides scope permissions. |

### Scope label

The header shows a subtitle indicating the active scope: **"Viewing: Your Team"**, **"Viewing: All Cases"**, etc. This updates automatically when the component loads.

### Column picker

The **Columns ▾** button opens a dropdown with a checkbox for each of the 12 columns. Changes apply immediately and reset to all-visible on page refresh. To change which columns are visible by default, edit `DEFAULT_COLUMNS` in `sfSltDashboard.js`:

```js
const DEFAULT_COLUMNS = [
    { key: 'caseNumber', label: 'Case #',  visible: true  },
    { key: 'severity',   label: 'Severity', visible: false }, // hidden by default
    // ...
];
```

### Sorting

Click any column header to sort ascending (▲). Click again to reverse (▼). Null values sort to the bottom. RAG Status sorts Red → Amber → Green (not alphabetically).

### Progress bar

Fill width = `(hours elapsed / SLT target) × 100%`, capped at 100%. The bar uses a fixed CSS gradient spanning the full track — green at the left edge, orange at 55%, red at 100%. As the bar fills, it progressively reveals the gradient.

### Things you can change

| What | Where | What to edit |
|---|---|---|
| Refresh interval | `sfSltDashboard.js` | `REFRESH_INTERVAL_MS` |
| RAG badge labels | `sfSltDashboard.js` | `RAG_LABEL` object |
| Default column visibility | `sfSltDashboard.js` | `DEFAULT_COLUMNS` array |
| Progress bar gradient | `sfSltDashboard.css` | `.progress-fill` `background` property |

---

## 11. Permission sets

### Base access

**`SLT Dashboard Access` (`SLTDashboardAccess`)** — required for every user. Grants:
- Read access to all 8 SLT custom fields on Case
- Apex class access to `SLTDashboardController`

### Scope permission sets

Four scope permission sets control what data each user sees. Assign exactly one per user alongside the base access set.

| Permission Set Name | Label | Scope |
|---|---|---|
| `SLTScope_All` | SLT Dashboard - Director Scope | All cases in the org |
| `SLTScope_Org` | SLT Dashboard - Manager Scope | All cases in the role subtree beneath the user |
| `SLTScope_Team` | SLT Dashboard - Technical Lead Scope | Cases for users in direct child roles |
| `SLTScope_Own` | SLT Dashboard - Agent Scope | Only the user's own cases |

Each scope permission set contains one **Custom Permission**:

| Custom Permission | Checked by the Apex controller |
|---|---|
| `SLT_Scope_All` | `FeatureManagement.checkPermission('SLT_Scope_All')` |
| `SLT_Scope_Org` | `FeatureManagement.checkPermission('SLT_Scope_Org')` |
| `SLT_Scope_Team` | `FeatureManagement.checkPermission('SLT_Scope_Team')` |
| `SLT_Scope_Own` | fallback — no explicit check needed |

For full assignment instructions, see **[SETUP.md](./SETUP.md)**.

---

## 12. Deploy and setup

For complete step-by-step instructions — including scope assignment, role hierarchy setup, and cache clearing — see **[SETUP.md](./SETUP.md)**.

Quick reference:

```bash
# Deploy everything
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS

# Deploy LWC only (clear browser cache after this — see SETUP.md)
sf project deploy start --source-dir force-app/main/default/lwc/sfSltDashboard --target-org YOUR_ORG_ALIAS

# Deploy Apex controller only
sf project deploy start --source-dir force-app/main/default/classes/SLTDashboardController.cls --target-org YOUR_ORG_ALIAS

# Deploy scope permissions and permission sets only
sf project deploy start \
  --source-dir force-app/main/default/customPermissions \
  --source-dir force-app/main/default/permissionsets/SLTScope_All.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Org.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Team.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Own.permissionset-meta.xml \
  --target-org YOUR_ORG_ALIAS

# Run tests
sf apex run test \
  --class-names SLTDashboardControllerTest \
  --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS --wait 10 --result-format human
```

---

## 13. Configuration reference

| What to change | File | What to look for |
|---|---|---|
| S1 first response target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `0.5` (first block) |
| S2 first response target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `2` (first block) |
| S3 first response target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `24` (first block) |
| S1 update target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `4` (second block) |
| S2 update target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `24` (second block) |
| S3 update target | `objects/Case/fields/SLT_Target_Hours__c.field-meta.xml` | `36` (second block) |
| Red threshold (hours) | `objects/Case/fields/SLT_RAG_Status__c.field-meta.xml` | `1` |
| Amber threshold (% remaining) | `objects/Case/fields/SLT_RAG_Status__c.field-meta.xml` | `0.4` |
| Dashboard refresh rate | `lwc/sfSltDashboard/sfSltDashboard.js` | `REFRESH_INTERVAL_MS` |
| Progress bar gradient | `lwc/sfSltDashboard/sfSltDashboard.css` | `.progress-fill` gradient |
| RAG badge label text | `lwc/sfSltDashboard/sfSltDashboard.js` | `RAG_LABEL` object |
| Default column visibility | `lwc/sfSltDashboard/sfSltDashboard.js` | `DEFAULT_COLUMNS` array |
| Priority → Severity mapping | `flows/Case_Set_SLT_Fields_On_Create.flow-meta.xml` | `<rules>` inside `<decisions>` |
| Pin dashboard to one user | Lightning App Builder → component properties | `ownerId` |

All file paths are relative to `force-app/main/default/`.

---

## 14. Edge cases

### Cases created before deployment

Cases that existed before deployment will not have `Severity__c` set, causing them to show as Red immediately. Use the backfill script in [SETUP.md](./SETUP.md) to fix this.

### Cases where Priority is blank

The flow maps blank Priority to S3. The case still gets an SLT target and shows correctly.

### Cases without a CaseMilestone record

If the org does not use Salesforce Entitlement Milestones, Target Date and Completion Date show `—`, and Violated is derived from `Hours_Remaining__c`. All other columns work normally.

### Cases with inbound emails only

If no outbound email has been sent, the trigger never fires. The case stays in Phase 1, counting from creation time against the first response SLT.

### Dashboard shows an error after deploying a new version

Salesforce caches the compiled LWC JavaScript in the browser. After deploying a new version of the component, clear the browser cache before reloading. See [SETUP.md](./SETUP.md) for the full cache-clearing steps.

### User with multiple scope permission sets

If a user is accidentally assigned more than one scope set, the highest scope wins. The Apex checks in order: `SLT_Scope_All → SLT_Scope_Org → SLT_Scope_Team → fallback`. Audit assignments via Setup → Permission Sets → Manage Assignments.

### Existing RAG_Status__c field

This org has a separate `RAG_Status__c` field managed by an unrelated AI Case Triage system. This dashboard uses `SLT_RAG_Status__c` — a completely separate formula field. The two coexist independently and do not interact.
