import { LightningElement, api, track } from 'lwc';
import getActiveCases from '@salesforce/apex/SLTDashboardController.getActiveCases';

const REFRESH_INTERVAL_MS = 30_000;
const TICK_INTERVAL_MS    = 1_000;

const RAG_LABEL = { Red: 'Critical', Amber: 'At risk', Green: 'On track' };
const RAG_ORDER = { Red: 0, Amber: 1, Green: 2 };
const NO_RULE_LABEL = 'No SLT rule';

const SOURCE_LABEL = { Rule: 'Rule', CaseMilestone: 'Milestone' };

const DEFAULT_COLUMNS = [
    { key: 'caseNumber',     label: 'Case #',         visible: true },
    { key: 'subject',        label: 'Subject',         visible: true },
    { key: 'ownerName',      label: 'Owner',           visible: true },
    { key: 'status',         label: 'Status',          visible: true },
    { key: 'severity',       label: 'Severity',        visible: true },
    { key: 'milestoneName',  label: 'Milestone Name',  visible: true },
    { key: 'targetDate',     label: 'Target Date',     visible: true },
    { key: 'timeRemaining',  label: 'Time Remaining',  visible: true },
    { key: 'progressBar',    label: 'Progress',        visible: true },
    { key: 'isViolated',     label: 'Violated',        visible: true },
    { key: 'completionDate', label: 'Completion Date', visible: true },
    { key: 'ragStatus',      label: 'RAG Status',      visible: true },
    { key: 'source',         label: 'Source',          visible: false },
];

// Maps column key → enriched case property used for sorting
const SORT_PROP = {
    caseNumber:     'caseNumber',
    subject:        'subject',
    ownerName:      'ownerName',
    status:         'status',
    severity:       'severity',
    milestoneName:  'milestoneName',
    targetDate:     'targetDate',
    timeRemaining:  'timeRemainingMins',
    progressBar:    'progressPct',
    isViolated:     'isViolated',
    completionDate: 'completionDate',
    ragStatus:      'ragStatus',
    source:         'sourceLabel',
};

// ── Pure helpers ──────────────────────────────────────────────────────────────

// Same rules as SLTRuleService: breached or under the Red threshold → Red,
// under Amber % of the window → Amber, otherwise Green.
function ragFor(remainingMins, windowMins, redThresholdMins, amberPercent) {
    if (remainingMins <= 0) return 'Red';
    if (remainingMins < redThresholdMins) return 'Red';
    if (windowMins > 0 && remainingMins < windowMins * amberPercent / 100) return 'Amber';
    return 'Green';
}

// Inline pill style from a configured hex colour. Text in the colour itself on a
// light tint when that is readable (WCAG AA against white); otherwise a solid
// background with black or white text, whichever contrasts more.
function severityPillStyle(hex) {
    if (!/^#[0-9a-fA-F]{6}$/.test(hex ?? '')) return null;
    const [r, g, b] = [1, 3, 5]
        .map(i => parseInt(hex.substring(i, i + 2), 16) / 255)
        .map(v => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (1.05 / (luminance + 0.05) >= 4.5) {
        return `background-color:${hex}1A;color:${hex}`;
    }
    return `background-color:${hex};color:${luminance > 0.179 ? '#080707' : '#ffffff'}`;
}

// "Xh Ym" (or "-Xh Ym" when breached). Under an hour, live rows add seconds
// ("42m 15s") because they tick every second.
function fmtMins(mins, withSeconds = false) {
    const totalSecs = Math.round(mins * 60);
    if (withSeconds && Math.abs(totalSecs) < 3600) {
        const sign = totalSecs < 0 ? '-' : '';
        const abs  = Math.abs(totalSecs);
        return sign + `${Math.floor(abs / 60)}m ${abs % 60}s`;
    }
    const total = Math.round(mins);
    const sign  = total < 0 ? '-' : '';
    const abs   = Math.abs(total);
    const h     = Math.floor(abs / 60);
    const m     = abs % 60;
    if (h > 0) return sign + (m > 0 ? `${h}h ${m}m` : `${h}h`);
    return sign + `${m}m`;
}

export default class SfSltDashboard extends LightningElement {

    @api ownerId = '';
    @api queueId = '';

    @track _cases           = [];
    @track error            = null;
    @track isLoading        = true;
    @track activeFilter     = 'All';
    @track columns          = DEFAULT_COLUMNS.map(c => ({ ...c }));
    @track showColumnPicker = false;
    @track sortColumn       = 'timeRemaining';
    @track sortDirection    = 'asc';
    @track scopeLabel       = '';
    @track totalCaseCount   = 0;
    @track isTruncated      = false;

    _rows              = [];   // raw server rows
    _redThresholdMins  = 0;
    _amberPercent      = 0;
    _timer             = null;
    _tickTimer         = null;

    // ── lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        this._load();
        this._timer     = setInterval(() => this._load(), REFRESH_INTERVAL_MS);
        this._tickTimer = setInterval(() => this._tick(), TICK_INTERVAL_MS);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
        clearInterval(this._tickTimer);
    }

    // ── data ──────────────────────────────────────────────────────────────────

    _load() {
        getActiveCases({ ownerId: this.ownerId || '', queueId: this.queueId || '' })
            .then(result => {
                this._rows             = result.cases;
                this._redThresholdMins = result.redThresholdMinutes   ?? 0;
                this._amberPercent     = result.amberThresholdPercent ?? 0;
                this.scopeLabel        = result.scopeLabel;
                this.totalCaseCount    = result.totalCaseCount ?? result.cases.length;
                this.isTruncated       = result.isTruncated === true;
                this._cases            = this._rows.map(c => this._enrich(c, Date.now()));
                this.error             = null;
            })
            .catch(err => {
                this.error = err?.body?.message ?? String(err);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    // Calendar-time rows count down every second from their deadline. Business-hours
    // rows (clock paused outside working hours) and rows without a rule keep their
    // server values until the next refresh. Re-renders only when something visible changes.
    _tick() {
        if (!this._rows.some(c => this._isLive(c))) return;
        const now  = Date.now();
        const next = this._rows.map(c => this._enrich(c, now));
        const changed = next.some((row, i) => row.displayKey !== this._cases[i]?.displayKey);
        if (changed) {
            this._cases = next;
        }
    }

    _isLive(c) {
        return !c.ruleMissing && !c.usesBusinessHours && c.deadline != null;
    }

    _enrich(c, now) {
        const ruleMissing = c.ruleMissing === true;
        const targetMins  = c.sltTargetHours != null ? c.sltTargetHours * 60 : null;
        let remainingMins = c.timeRemainingMins;
        let elapsedMins   = c.hoursElapsed != null ? c.hoursElapsed * 60 : null;
        let rag           = c.ragStatus ?? null;
        let isViolated    = c.isViolated === true;

        if (this._isLive(c)) {
            remainingMins = (new Date(c.deadline).getTime() - now) / 60000;
            elapsedMins   = targetMins != null ? targetMins - remainingMins : elapsedMins;
            rag           = ragFor(remainingMins, targetMins, this._redThresholdMins, this._amberPercent);
            isViolated    = isViolated || remainingMins <= 0;
        }

        const isBreached = !ruleMissing && (isViolated || (remainingMins != null && remainingMins <= 0));
        const pct = ruleMissing
            ? 0
            : targetMins > 0
                ? Math.max(0, Math.min(Math.round((elapsedMins / targetMins) * 100), 100))
                : (isBreached ? 100 : 0);

        const ragLabel    = ruleMissing ? NO_RULE_LABEL : (RAG_LABEL[rag] ?? RAG_LABEL.Green);
        const ragClass    = ruleMissing ? 'rag-none' : `rag-${(rag ?? 'Green').toLowerCase()}`;
        const timeDisplay = remainingMins != null ? fmtMins(remainingMins, this._isLive(c)) : '—';
        const pillStyle   = severityPillStyle(c.severityColor);

        return {
            Id:                    c.caseId,
            caseNumber:            c.caseNumber,
            subject:               c.subject,
            ownerName:             c.ownerName,
            status:                c.status,
            severity:              c.severity,
            severityLabel:         c.severityLabel,
            milestoneName:         c.milestoneName,
            targetDate:            c.targetDate,
            timeRemainingMins:     remainingMins,
            isViolated:            isViolated,
            completionDate:        c.completionDate,
            ragStatus:             ruleMissing ? null : rag,
            sourceLabel:           SOURCE_LABEL[c.source] ?? c.source,
            recordUrl:             `/lightning/r/Case/${c.caseId}/view`,
            targetDateDisplay:     this._fmtDate(c.targetDate),
            completionDateDisplay: this._fmtDate(c.completionDate),
            timeDisplay:           timeDisplay,
            timeClass:             isBreached ? 'time-value time-breached' : 'time-value',
            progressPct:           pct,
            progressStyle:         `width:${pct}%`,
            ragLabel:              ragLabel,
            ragBadgeClass:         `rag-badge ${ragClass}`,
            severityClass:         pillStyle ? 'sev-pill' : `sev-pill sev-${(c.severity ?? '').toLowerCase()}`,
            severityStyle:         pillStyle ?? '',
            isViolatedClass:       isViolated ? 'violated-badge violated' : 'violated-badge ok',
            isViolatedLabel:       isViolated ? 'Yes' : 'No',
            ariaLinkLabel:         'Open case ' + c.caseNumber,
            ariaRagLabel:          'RAG status: ' + ragLabel,
            displayKey:            `${timeDisplay}|${rag}|${pct}|${isViolated}`
        };
    }

    _fmtDate(isoStr) {
        if (!isoStr) return '—';
        return new Date(isoStr).toLocaleDateString(undefined, {
            year: 'numeric', month: 'short', day: 'numeric'
        });
    }

    // ── getters — header ──────────────────────────────────────────────────────

    get truncationNote() {
        const shown = this._cases.length;
        if (this.isTruncated) {
            return `Showing the most urgent ${shown} of ${this.totalCaseCount}+ open cases`;
        }
        if (this.totalCaseCount > shown) {
            return `Showing the most urgent ${shown} of ${this.totalCaseCount} open cases`;
        }
        return '';
    }

    // ── getters — summary cards ───────────────────────────────────────────────

    get totalCount() { return this._cases.length; }
    get redCount()   { return this._cases.filter(c => c.ragStatus === 'Red').length; }
    get amberCount() { return this._cases.filter(c => c.ragStatus === 'Amber').length; }
    get greenCount() { return this._cases.filter(c => c.ragStatus === 'Green').length; }

    get ariaLabelTotal() { return this.totalCount + ' total active cases'; }
    get ariaLabelRed()   { return this.redCount   + ' critical cases'; }
    get ariaLabelAmber() { return this.amberCount + ' at-risk cases'; }
    get ariaLabelGreen() { return this.greenCount + ' on-track cases'; }

    // ── getters — table (filtered + sorted) ───────────────────────────────────

    get filteredCases() {
        let cases = this.activeFilter === 'All'
            ? this._cases
            : this._cases.filter(c => c.ragStatus === this.activeFilter);

        if (!this.sortColumn) return cases;

        const dir  = this.sortDirection === 'asc' ? 1 : -1;
        const prop = SORT_PROP[this.sortColumn] ?? this.sortColumn;

        return [...cases].sort((a, b) => {
            let va = a[prop];
            let vb = b[prop];

            if (va == null && vb == null) return 0;
            if (va == null) return 1;
            if (vb == null) return -1;

            if (prop === 'ragStatus') {
                return dir * ((RAG_ORDER[va] ?? 3) - (RAG_ORDER[vb] ?? 3));
            }
            if (typeof va === 'string') return dir * va.localeCompare(vb);
            return dir * (va > vb ? 1 : va < vb ? -1 : 0);
        });
    }

    get filteredCount() { return this.filteredCases.length; }
    get hasResults()    { return this.filteredCases.length > 0; }

    // ── getters — column visibility ───────────────────────────────────────────

    _colVisible(key) {
        const col = this.columns.find(c => c.key === key);
        return col ? col.visible : true;
    }

    get showCaseNumber()     { return this._colVisible('caseNumber'); }
    get showSubject()        { return this._colVisible('subject'); }
    get showOwnerName()      { return this._colVisible('ownerName'); }
    get showStatus()         { return this._colVisible('status'); }
    get showSeverity()       { return this._colVisible('severity'); }
    get showMilestoneName()  { return this._colVisible('milestoneName'); }
    get showTargetDate()     { return this._colVisible('targetDate'); }
    get showTimeRemaining()  { return this._colVisible('timeRemaining'); }
    get showProgressBar()    { return this._colVisible('progressBar'); }
    get showIsViolated()     { return this._colVisible('isViolated'); }
    get showCompletionDate() { return this._colVisible('completionDate'); }
    get showRagStatus()      { return this._colVisible('ragStatus'); }
    get showSource()         { return this._colVisible('source'); }

    // ── getters — sortable header classes ─────────────────────────────────────

    _thClass(key) {
        if (this.sortColumn !== key) return 'sortable-th';
        return 'sortable-th ' + (this.sortDirection === 'asc' ? 'sort-asc' : 'sort-desc');
    }

    get thCaseNumber()     { return this._thClass('caseNumber'); }
    get thSubject()        { return this._thClass('subject'); }
    get thOwnerName()      { return this._thClass('ownerName'); }
    get thStatus()         { return this._thClass('status'); }
    get thSeverity()       { return this._thClass('severity'); }
    get thMilestoneName()  { return this._thClass('milestoneName'); }
    get thTargetDate()     { return this._thClass('targetDate'); }
    get thTimeRemaining()  { return this._thClass('timeRemaining'); }
    get thProgressBar()    { return this._thClass('progressBar'); }
    get thIsViolated()     { return this._thClass('isViolated'); }
    get thCompletionDate() { return this._thClass('completionDate'); }
    get thRagStatus()      { return this._thClass('ragStatus'); }
    get thSource()         { return this._thClass('source'); }

    // ── getters — filter button classes ───────────────────────────────────────

    get allFilterClass()   { return this._btnClass('All',   ''); }
    get redFilterClass()   { return this._btnClass('Red',   'btn-red'); }
    get amberFilterClass() { return this._btnClass('Amber', 'btn-amber'); }
    get greenFilterClass() { return this._btnClass('Green', 'btn-green'); }

    _btnClass(filter, colorMod) {
        const active = this.activeFilter === filter ? ' active' : '';
        return `filter-btn ${colorMod}${active}`.trim();
    }

    // ── handlers ──────────────────────────────────────────────────────────────

    handleFilterClick(event) {
        this.activeFilter = event.currentTarget.dataset.filter;
    }

    handleSortClick(event) {
        const key = event.currentTarget.dataset.sort;
        if (this.sortColumn === key) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortColumn    = key;
            this.sortDirection = 'asc';
        }
    }

    toggleColumnPicker() {
        this.showColumnPicker = !this.showColumnPicker;
    }

    handleColumnToggle(event) {
        const key     = event.target.dataset.key;
        const checked = event.target.checked;
        this.columns  = this.columns.map(col =>
            col.key === key ? { ...col, visible: checked } : col
        );
    }
}
