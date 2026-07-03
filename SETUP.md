# SF SLT Dashboard — Setup Guide

Complete instructions for deploying the SF SLT Dashboard to a Salesforce org and configuring it for your team.

---

## Prerequisites

Before you begin, make sure you have the following installed:

- **Salesforce CLI** — [download here](https://developer.salesforce.com/tools/salesforcecli)
- **Node.js** — required by the Salesforce CLI
- **Git**

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
```

A browser window will open. Log in with your Salesforce credentials. Once done, verify the connection:

```bash
sf org display --target-org YOUR_ORG_ALIAS
```

### 3. Deploy all metadata

```bash
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

This deploys everything in one command:
- Custom fields and formula fields on Case
- Automation flows
- Apex trigger and controller
- LWC dashboard component
- Permission sets (base access + all 4 scope sets)
- Custom permissions (scope definitions)

### 4. Run the tests

Confirm everything deployed cleanly before proceeding:

```bash
sf apex run test \
  --class-names SLTDashboardControllerTest \
  --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS \
  --wait 10 \
  --result-format human
```

All tests should pass. If any fail, do not proceed until resolved.

### 5. Backfill Severity on existing cases (if needed)

Cases created before deployment will not have `Severity__c` populated, which means they will show as Red immediately.

> **Before running the script:** the user executing it must have the `SLTDashboardAccess` permission set assigned, otherwise the query will fail with "No such column 'Severity__c'". Assign it first if needed:
> ```bash
> sf org assign permset --name SLTDashboardAccess --target-org YOUR_ORG_ALIAS
> ```

To backfill all currently open cases, go to **Developer Console** → **Debug** → **Open Execute Anonymous Window**, paste the following, and click **Execute**:

```apex
List<Case> cases = [
    SELECT Id, Priority, Severity__c
    FROM Case
    WHERE Status != 'Closed'
    AND Severity__c = null
];

for (Case c : cases) {
    if      (c.Priority == 'High')   c.Severity__c = 'S1';
    else if (c.Priority == 'Medium') c.Severity__c = 'S2';
    else                             c.Severity__c = 'S3';
}

update cases;
```

---

## Part 2 — Salesforce Setup

### 1. Activate the flows

After deployment, both flows must be active.

1. Go to **Setup** → search for **Flows** → open it
2. Find **Case – Set SLT Fields On Create** → confirm **Status: Active**
3. Find **Case – Switch Milestone to Update on First Response** → confirm **Status: Active**

If either shows as Inactive, click the flow name → click **Activate**.

### 2. Verify the Apex trigger is active

1. Go to **Setup** → search for **Apex Triggers** → open it
2. Find **SLTEmailMessageTrigger** → confirm it is **Active**

The trigger deploys as active by default — this is just a sanity check.

### 3. Create the dashboard Lightning page

1. Go to **Setup** → search for **Lightning App Builder** → open it
2. Click **New**
3. Select **App Page** → click **Next**
4. Enter a label (e.g. `SLT Dashboard`) → click **Next**
5. Select **One Region** layout → click **Done**
6. In the component panel on the left, search for **sfSltDashboard**
7. Drag it onto the canvas
8. *(Optional)* In the right-hand Properties panel, set **Filter by Owner ID** to a Salesforce User ID to pin the dashboard to one specific user's cases. Leave blank to use role-based scoping.
9. Click **Save**
10. Click **Activate**
11. In the activation dialog:
    - Set **Page Access** to **Org Default** (or assign to specific apps/profiles)
    - Select **Desktop** as the form factor
    - Click **Save**

### 4. Add the dashboard to your app navigation

1. Go to **Setup** → **App Manager** → find the app your agents use (e.g. Service Console) → click **Edit**
2. Go to the **Navigation Items** tab
3. Add the Lightning page you created as a navigation item
4. Click **Save**

Agents can now find the dashboard from the app's navigation bar.

### 5. Assign permissions to users

Every user who needs access to the dashboard requires **two** permission set assignments:

| Permission Set | Purpose |
|---|---|
| `SLT Dashboard Access` | Grants access to the Apex controller and all SLT fields on Case |
| One scope set (see below) | Controls how much data the user sees on the dashboard |

**If a user has `SLT Dashboard Access` but no scope set → dashboard shows their own cases only (safe default).**

**If a user has a scope set but not `SLT Dashboard Access` → dashboard throws an error.**

---

#### Scope permission sets

| Permission Set | Label in UI | Who to assign it to | What the dashboard shows |
|---|---|---|---|
| `SLTScope_All` | SLT Dashboard - Director Scope | Directors | All open cases across the entire org |
| `SLTScope_Org` | SLT Dashboard - Manager Scope | Managers | All cases for every agent and team beneath them in the role hierarchy |
| `SLTScope_Team` | SLT Dashboard - Technical Lead Scope | Technical Leads | All cases for agents in their direct team (one level down in the role hierarchy) |
| `SLTScope_Own` | SLT Dashboard - Agent Scope | Agents | Only their own cases |

> **Note:** `SLTScope_Org` and `SLTScope_Team` use the Salesforce role hierarchy to find subordinate users. The role hierarchy must be configured in your org for these scopes to work correctly. `SLTScope_All` and `SLTScope_Own` do not depend on roles.

---

#### Assigning via the Salesforce UI

1. Go to **Setup → Users → Users**
2. Click the user's name
3. Scroll to **Permission Set Assignments** → click **Edit Assignments**
4. Move `SLT Dashboard Access` and the correct scope set to the **Enabled** column
5. Click **Save**

Repeat for each user.

---

#### Assigning via the CLI (faster for multiple users)

```bash
# Director
sf org assign permset \
  --name SLTDashboardAccess \
  --name SLTScope_All \
  --on-behalf-of director@yourorg.com \
  --target-org YOUR_ORG_ALIAS

# Manager
sf org assign permset \
  --name SLTDashboardAccess \
  --name SLTScope_Org \
  --on-behalf-of manager@yourorg.com \
  --target-org YOUR_ORG_ALIAS

# Technical Lead
sf org assign permset \
  --name SLTDashboardAccess \
  --name SLTScope_Team \
  --on-behalf-of lead@yourorg.com \
  --target-org YOUR_ORG_ALIAS

# Agent
sf org assign permset \
  --name SLTDashboardAccess \
  --name SLTScope_Own \
  --on-behalf-of agent@yourorg.com \
  --target-org YOUR_ORG_ALIAS
```

---

#### Assigning a scope to all users in a role (bulk)

1. Go to **Setup → Permission Sets → SLT Dashboard - [scope] Scope → Manage Assignments**
2. Click **Add Assignments**
3. Use the **Role** filter at the top to narrow the list
4. Select all relevant users → click **Assign**

Repeat for each scope/role combination.

---

#### A user should only ever have one scope set

If a user somehow has more than one, the dashboard uses the highest scope it finds, checked in this order: `All → Org → Team → Own`. To avoid confusion, audit assignments regularly via **Setup → Permission Sets → [scope set] → Manage Assignments**.

### 6. Configure the role hierarchy (for Manager and TL scopes)

If you are using `SLTScope_Org` (Manager) or `SLTScope_Team` (Technical Lead), users in those roles must have the correct role set in Salesforce for the hierarchy lookup to work.

1. Go to **Setup → Users → Users**
2. Click the user → click **Edit**
3. Set the **Role** field to the appropriate role
4. Click **Save**

The role hierarchy itself (which role is the parent of which) is configured under **Setup → Roles**.

> The scoping logic does not require any specific role names. It traverses whatever parent–child role structure exists in your org dynamically.

### 7. Add SLT fields to the Case page layout (optional but recommended)

This lets users see SLT data directly on a case record without opening the dashboard.

1. Go to **Setup → Object Manager → Case → Page Layouts**
2. Edit the layout your agents use (typically `Case Layout` or a support-specific layout)
3. Drag the following fields into the Details section:
   - **Severity** (`Severity__c`)
   - **Milestone Type** (`Milestone_Type__c`)
   - **First Response Date** (`First_Response_Date__c`)
   - **Last Update Date** (`Last_Update_Date__c`)
   - **Hours Remaining** (`Hours_Remaining__c`)
   - **SLT RAG Status** (`SLT_RAG_Status__c`)
4. Click **Save**

---

## Part 3 — After Deploying Updates

### Clearing the Lightning cache

Salesforce caches the compiled LWC JavaScript in the browser. After deploying a new version of the dashboard component, users may still see the old version until the cache is cleared.

**If the dashboard shows an error after a fresh deploy:**

1. Open the browser's developer tools (`Cmd+Option+I` on Mac / `F12` on Windows)
2. Go to the **Application** tab
3. Click **Storage** in the left sidebar → click **Clear site data**
4. Reload the page

Alternatively, test in an **incognito / private window** first — if it works there but not in the normal browser, it is a cache issue.

You can also run this in the browser console on the Salesforce page, then reload:

```javascript
localStorage.clear(); sessionStorage.clear();
```

### Redeploying specific files

To redeploy only what changed:

```bash
# LWC component only (always clear browser cache after this)
sf project deploy start \
  --source-dir force-app/main/default/lwc/sfSltDashboard \
  --target-org YOUR_ORG_ALIAS

# Apex controller only
sf project deploy start \
  --source-dir force-app/main/default/classes/SLTDashboardController.cls \
  --target-org YOUR_ORG_ALIAS

# Scope permission sets and custom permissions only
sf project deploy start \
  --source-dir force-app/main/default/customPermissions \
  --source-dir force-app/main/default/permissionsets/SLTScope_All.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Org.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Team.permissionset-meta.xml \
  --source-dir force-app/main/default/permissionsets/SLTScope_Own.permissionset-meta.xml \
  --target-org YOUR_ORG_ALIAS

# A specific formula field (e.g. after changing an SLT threshold)
sf project deploy start \
  --source-dir force-app/main/default/objects/Case/fields/SLT_Target_Hours__c.field-meta.xml \
  --target-org YOUR_ORG_ALIAS

# Everything at once
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

### Running tests after a change

```bash
sf apex run test \
  --class-names SLTDashboardControllerTest \
  --class-names SLTEmailMessageTriggerTest \
  --target-org YOUR_ORG_ALIAS \
  --wait 10 \
  --result-format human
```

---

## Appendix — Custom Metadata Created (Summary)

Reference list of everything custom-built and deployed by this project, regardless of type. Standard Salesforce objects/fields (Case, EmailMessage, CaseMilestone, Priority, Status, OwnerId, CreatedDate) are **not** listed here.

### Custom fields on Case (8)

| Field API Name | Type | Purpose |
|---|---|---|
| `Severity__c` | Picklist (S1/S2/S3) | Set by flow from `Priority` on case creation |
| `Milestone_Type__c` | Picklist (First Response/Update/Resolution) | Tracks current SLT phase |
| `First_Response_Date__c` | DateTime | Stamped on first outbound email |
| `Last_Update_Date__c` | DateTime | Stamped on every outbound email |
| `SLT_Target_Hours__c` | Formula (Number) | Target hours for current phase |
| `Hours_Elapsed__c` | Formula (Number) | Hours since current phase started |
| `Hours_Remaining__c` | Formula (Number) | Target minus elapsed |
| `SLT_RAG_Status__c` | Formula (Text) | Red/Amber/Green |

### Custom Permissions (4)

`SLT_Scope_All`, `SLT_Scope_Org`, `SLT_Scope_Team`, `SLT_Scope_Own`

### Permission Sets (5)

`SLTDashboardAccess` (base access), `SLTScope_All`, `SLTScope_Org`, `SLTScope_Team`, `SLTScope_Own`

### Apex (3 classes + 1 trigger)

`SLTDashboardController.cls`, `SLTDashboardControllerTest.cls`, `SLTEmailMessageTriggerTest.cls`, `SLTEmailMessageTrigger.trigger`

### Flows (2)

`Case_Set_SLT_Fields_On_Create`, `Case_Update_Milestone_On_First_Response`

### Lightning Web Component (1)

`sfSltDashboard`

### Not custom (for clarity)

`CaseMilestone` and its fields are standard Salesforce Entitlement Milestone objects, used but not created by this project.
