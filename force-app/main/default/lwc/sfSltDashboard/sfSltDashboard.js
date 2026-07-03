import { LightningElement, api, track } from 'lwc';
import getActiveCases from '@salesforce/apex/SLTDashboardController.getActiveCases';

const REFRESH_INTERVAL_MS = 30_000;

const RAG_LABEL = { Red: 'Critical', Amber: 'At risk', Green: 'On track' };
const RAG_ORDER = { Red: 0, Amber: 1, Green: 2 };

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
};

export default class SfSltDashboard extends LightningElement {

    @api ownerId = '';

    @track _cases           = [];
    @track error            = null;
    @track isLoading        = true;
    @track activeFilter     = 'All';
    @track columns          = DEFAULT_COLUMNS.map(c => ({ ...c }));
    @track showColumnPicker = false;
    @track sortColumn       = 'timeRemaining';
    @track sortDirection    = 'asc';
    @track scopeLabel       = '';

    _timer = null;

    // ── lifecycle ─────────────────────────────────────────────────────────────

    connectedCallback() {
        this._load();
        this._timer = setInterval(() => this._load(), REFRESH_INTERVAL_MS);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    // ── data ──────────────────────────────────────────────────────────────────

    _load() {
        getActiveCases({ ownerId: this.ownerId || '' })
            .then(result => {
                this._cases    = result.cases.map(c => this._enrich(c));
                this.scopeLabel = result.scopeLabel;
                this.error     = null;
            })
            .catch(err => {
                this.error = err?.body?.message ?? String(err);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    _enrich(c) {
        const rag           = c.ragStatus         ?? 'Green';
        const remainingMins = c.timeRemainingMins ?? 0;
        const target        = c.sltTargetHours    ?? 0;
        const elapsed       = c.hoursElapsed      ?? 0;
        const isBreached    = c.isViolated || remainingMins <= 0;

        const pct = target > 0
            ? Math.min(Math.round((elapsed / target) * 100), 100)
            : (isBreached ? 100 : 0);

        return {
            Id:                    c.caseId,
            caseNumber:            c.caseNumber,
            subject:               c.subject,
            ownerName:             c.ownerName,
            status:                c.status,
            severity:              c.severity,
            milestoneName:         c.milestoneName,
            targetDate:            c.targetDate,
            timeRemainingMins:     remainingMins,
            isViolated:            c.isViolated,
            completionDate:        c.completionDate,
            ragStatus:             rag,
            recordUrl:             `/lightning/r/Case/${c.caseId}/view`,
            targetDateDisplay:     this._fmtDate(c.targetDate),
            completionDateDisplay: this._fmtDate(c.completionDate),
            timeDisplay:           this._fmtMins(remainingMins),
            timeClass:             isBreached ? 'time-value time-breached' : 'time-value',
            progressPct:           pct,
            progressStyle:         `width:${pct}%`,
            ragLabel:              RAG_LABEL[rag] ?? 'On track',
            ragBadgeClass:         `rag-badge rag-${rag.toLowerCase()}`,
            severityClass:         `sev-pill sev-${(c.severity ?? '').toLowerCase()}`,
            isViolatedClass:       c.isViolated ? 'violated-badge violated' : 'violated-badge ok',
            isViolatedLabel:       c.isViolated ? 'Yes' : 'No',
            ariaLinkLabel:         'Open case ' + c.caseNumber,
            ariaRagLabel:          'RAG status: ' + (RAG_LABEL[rag] ?? 'On track')
        };
    }

    _fmtMins(mins) {
        const sign = mins < 0 ? '-' : '';
        const abs  = Math.abs(mins);
        const h    = Math.floor(abs / 60);
        const m    = Math.round(abs % 60);
        if (h > 0) return sign + (m > 0 ? `${h}h ${m}m` : `${h}h`);
        return sign + `${m}m`;
    }

    _fmtDate(isoStr) {
        if (!isoStr) return '—';
        return new Date(isoStr).toLocaleDateString(undefined, {
            year: 'numeric', month: 'short', day: 'numeric'
        });
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
