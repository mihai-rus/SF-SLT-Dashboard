# SF SLT Dashboard

### Business Overview

---

## 1. What Is This?

The SF SLT Dashboard is a live monitoring tool built inside Salesforce. It gives support teams a clear, real-time view of every open case and whether it is on track to meet its contractual Service Level Target (SLT).

The dashboard uses a **traffic-light system** — Green, Amber, and Red — to indicate the health of each case at a glance:

| Colour | Meaning |
|---|---|
| Green — "On track" | The case has enough time remaining to meet its target |
| Amber — "At risk" | Less than 40% of the allowed time is left — attention needed |
| Red — "Critical" | The deadline has been breached, or less than 1 hour remains |
| Grey — "No SLT rule" | No time target has been configured for this case's severity |

These are the default thresholds; an administrator can change them in Salesforce Setup without any development work.

The page refreshes automatically every 30 seconds, and the time remaining counts down every second in between. No one needs to manually reload or run a report.

---

## 2. The Problem It Solves

Support teams operate under contractual time commitments — cases must receive a first response and regular updates within agreed windows, which vary by how critical the issue is. Until now there was no single, live view that showed which cases were at risk across the team.

Without this tool, managers and leads had to rely on static reports or individual case checks to spot cases about to miss their SLT. By the time a breach was noticed, it was often too late to act.

---

## 3. How It Works (In Plain Terms)

When a customer opens a case, the system automatically assigns a severity level (S1, S2, or S3) based on the priority of the issue. A clock starts immediately.

- The first thing the clock measures is: **has the agent sent a first response yet?**
- Once a response is sent, the clock resets and starts measuring: **how long since the last update?**
- Every time an agent sends a follow-up email from within Salesforce, the clock resets again, giving the agent a fresh window.

The dashboard reads these clocks in real time and shows each case's traffic-light status. There are no manual steps required from agents or managers to keep the dashboard current — it updates itself.

---

## 4. Severity Levels and Time Targets

Cases are classified into three severity levels based on business impact:

| Severity | Description | First Response Target | Between-Update Target |
|---|---|---|---|
| S1 — Production Down | The customer's system is completely non-functional | 30 minutes | 4 hours |
| S2 — Production Impaired | The customer's system is degraded but partly working | 2 hours | 24 hours |
| S3 — Minor Issue | Low-impact or non-urgent issue | 24 hours | 36 hours |

The severity is set automatically when a case is created, based on the Priority field, so agents do not need to set it manually.

These are the standard targets. Your Salesforce administrator can change any target, the Priority-to-severity mapping, the severity names and colours, or introduce different severity levels (for example P1–P4) directly in Salesforce Setup — no code changes or releases are needed. Targets can also be set to count only business hours, so the clock pauses outside working hours.

---

## 5. Who Sees What

The dashboard automatically shows each person the right scope of cases based on their role. There is nothing to configure day to day — access is managed once by an administrator.

| Role | Cases shown |
|---|---|
| Agent | Their own open cases only |
| Technical Lead | Cases owned by the agents they lead |
| Manager | All cases within their team and the teams beneath them |
| Director | All open cases across the organisation |

A manager who opens the dashboard sees exactly the cases they are responsible for — no more, no less. The dashboard also shows a label (e.g. "Your Organisation" or "Your Team") so the user always knows the scope they are viewing.

---

## 6. Key Features

- **Live traffic-light view** — every case is colour-coded by its current SLT health.
- **Summary cards** — at the top of the dashboard, a count of Red, Amber, and Green cases is shown instantly.
- **Filter by status** — click a traffic-light card to see only Red cases, only Amber, etc.
- **Sortable columns** — sort by time remaining, case number, severity, owner, and more.
- **Column picker** — show or hide columns to focus on what matters.
- **Progress bar** — each row shows a colour-coded bar indicating how much of the SLT window has been used.
- **Live countdown** — time remaining counts down every second, showing seconds when less than an hour is left.
- **Auto-refresh** — the page reloads its data every 30 seconds without any manual action.
- **Most urgent first** — when a scope contains a very large number of open cases, the dashboard shows the most urgent ones and says how many it is showing out of the total.

---

## 7. What Triggers the Clock to Reset

The update clock resets each time an agent sends an outbound email from within the Salesforce case. This is the action Salesforce can track automatically.

**Important:** emails sent from Outlook, Gmail, or any external email client are not visible to Salesforce and will not reset the clock. Agents should always respond from within the Salesforce case to ensure their SLT timer is updated.

---

## 8. Getting Access

Access is controlled by your Salesforce administrator. To access the dashboard, a user needs:

1. **Base access** — permission to view the SLT fields and the dashboard itself. This is required for everyone; without it the dashboard shows an error instead of cases.
2. **A scope level** — one of Agent, Technical Lead, Manager, or Director, which controls how much data they can see.

To request access, contact your Salesforce administrator and specify which scope level is appropriate for your role.

---

## 9. How the System Is Built (Overview)

The dashboard is built entirely within Salesforce — there are no external tools, third-party services, or AI components involved. All calculations happen live inside Salesforce at the moment the dashboard loads. There are no scheduled overnight jobs or batch processes; the numbers are always current.

The system has four main parts working together:

1. **Configuration** — the time targets, severity mapping and traffic-light thresholds are settings an administrator maintains in Salesforce Setup.
2. **Automation rules** — when a case is created or an email is sent, Salesforce automatically updates the relevant timestamps and severity fields. Agents do not need to do anything extra.
3. **Live calculations** — Salesforce computes time elapsed, time remaining, and traffic-light status on the fly, from the timestamps and the configured targets.
4. **The dashboard** — reads those live values every 30 seconds and presents them in the table with filtering, sorting, and summary cards.

---

## 10. Frequently Asked Questions

**Does the dashboard affect how agents work?**
No. Agents continue working cases as normal. The only important habit is responding to customers from within Salesforce (rather than an external email client) so the system can track updates accurately.

**What happens if a case was created before the system was set up?**
They display correctly straight away: if an older case has no severity, the dashboard works it out from the case's Priority. An administrator can optionally run a one-time update to store the severity on those cases for reporting.

**Can a manager pin the dashboard to show one specific person's cases?**
Yes. An administrator can configure a version of the dashboard page that always shows one user's cases, regardless of who is viewing it. This is useful for a manager who wants a dedicated view of a specific team member's workload.

**What does "RAG" mean?**
In this dashboard, RAG stands for Red / Amber / Green — the traffic-light colour system. It has no relation to AI or machine learning.

**Is data from this dashboard shared outside Salesforce?**
No. Everything stays within your Salesforce org. There are no external integrations.

**Who can change the time targets or thresholds?**
A Salesforce administrator, in Setup → Custom Metadata Types. Changes take effect on the dashboard's next refresh; no release is needed.
