// "Register your school" page (Views/Site/SchoolOnboarding). Checks the answers, builds a
// WhatsApp message and opens wa.me with it, addressed to the support number in the form's
// data-wa attribute (Support:WhatsApp). Nothing is sent to our server. A draft is kept in
// this browser only (localStorage), so a half-filled form survives a reload.
(function () {
    var STATES = ['Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh', 'Goa', 'Gujarat', 'Haryana',
        'Himachal Pradesh', 'Jharkhand', 'Karnataka', 'Kerala', 'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya',
        'Mizoram', 'Nagaland', 'Odisha', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu', 'Telangana', 'Tripura',
        'Uttar Pradesh', 'Uttarakhand', 'West Bengal', 'Andaman and Nicobar Islands', 'Chandigarh',
        'Dadra and Nagar Haveli and Daman and Diu', 'Delhi', 'Jammu and Kashmir', 'Ladakh', 'Lakshadweep', 'Puducherry'];
    var MODULES = ['Fees', 'Attendance', 'Exams & report cards', 'Timetable & homework', 'Transport', 'Inventory / store',
        'Staff payroll & leave', 'Expenses & cash book', 'WhatsApp alerts to parents', 'Parent app'];
    var DRAFT_KEY = 'school-onboarding-draft';
    var MOBILE_MSG = 'Enter a 10-digit mobile number starting with 6, 7, 8 or 9.';

    var form = document.getElementById('onbForm');
    if (!form) return;
    var sendTo = (form.getAttribute('data-wa') || '').replace(/\D/g, '');

    function byId(id) { return document.getElementById(id); }

    // The lists are plain text we wrote above, but escape anyway so a later edit can't break the HTML.
    function escHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function fillSelect(el, list, first) {
        var html = '<option value="">' + escHtml(first) + '</option>';
        for (var i = 0; i < list.length; i++) html += '<option>' + escHtml(list[i]) + '</option>';
        el.innerHTML = html;
    }

    fillSelect(byId('state'), STATES, 'Select');
    fillSelect(byId('boardState'), STATES, 'Select state');

    var modHtml = '';
    for (var m = 0; m < MODULES.length; m++) {
        modHtml += '<label class="chk" for="m' + m + '"><input type="checkbox" id="m' + m + '" name="modules" value="'
                 + escHtml(MODULES[m]) + '"> ' + escHtml(MODULES[m]) + '</label>';
    }
    byId('modules').innerHTML = modHtml;

    function toggleBoardState() {
        var on = byId('board').value === 'State Board';
        byId('boardStateWrap').hidden = !on;
        byId('boardState').required = on;
    }
    byId('board').addEventListener('change', toggleBoardState);

    function copyAdmin() {
        if (!byId('adminSame').checked) return;
        byId('adminName').value = byId('contactName').value;
        byId('adminEmail').value = byId('contactEmail').value;
        byId('adminPhone').value = byId('contactPhone').value;
    }
    byId('adminSame').addEventListener('change', copyAdmin);
    ['contactName', 'contactEmail', 'contactPhone'].forEach(function (id) {
        byId(id).addEventListener('input', copyAdmin);
    });

    // ───────────── draft kept on this device only ─────────────
    function saveDraft() {
        try {
            var d = {};
            form.querySelectorAll('input,select,textarea').forEach(function (el) {
                d[el.id] = el.type === 'checkbox' ? el.checked : el.value;
            });
            localStorage.setItem(DRAFT_KEY, JSON.stringify(d));
        } catch (e) { }
    }
    function loadDraft() {
        try {
            var d = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null');
            if (!d) return;
            Object.keys(d).forEach(function (id) {
                var el = byId(id);
                if (!el || !form.contains(el)) return;
                if (el.type === 'checkbox') el.checked = !!d[id]; else el.value = d[id];
            });
        } catch (e) { }
    }
    loadDraft();
    toggleBoardState();
    form.addEventListener('input', saveDraft);
    form.addEventListener('change', saveDraft);

    // ───────────── checks ─────────────
    // Each rule returns '' when the value is fine, or the message to show.
    var RULES = {
        contactPhone: function (v) { return /^[6-9]\d{9}$/.test(v) ? '' : MOBILE_MSG; },
        adminPhone: function (v) { return /^[6-9]\d{9}$/.test(v) ? '' : MOBILE_MSG; },
        pincode: function (v) { return /^[1-9]\d{5}$/.test(v) ? '' : 'Enter the 6-digit pincode.'; },
        contactEmail: function (v) { return !v || /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) ? '' : 'Check the email address.'; },
        adminEmail: function (v) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) ? '' : 'Enter a valid email address for the admin login.'; },
        students: function (v) { return !v || /^\d{1,5}$/.test(v) ? '' : 'Enter a number, e.g. 450.'; }
    };

    function setErr(el, msg) {
        var field = el.closest('.field');
        if (!field) return;
        var box = field.querySelector('.err');
        if (!box) {
            box = document.createElement('div');
            box.className = 'err';
            field.appendChild(box);
        }
        box.textContent = msg || '';
        field.classList.toggle('bad', !!msg);
    }

    // Returns the first field with a problem, or null when everything is fine.
    function validate() {
        var first = null;
        form.querySelectorAll('input:not([type=checkbox]),select,textarea').forEach(function (el) {
            if (el.closest('[hidden]')) { setErr(el, ''); return; }
            var v = el.value.trim();
            var msg = '';
            if (el.required && !v) msg = 'This is required.';
            else if (RULES[el.id]) msg = RULES[el.id](v);
            setErr(el, msg);
            if (msg && !first) first = el;
        });
        if (!byId('consent').checked) {
            byId('consentErr').textContent = 'Please confirm the details are correct.';
            first = first || byId('consent');
        } else {
            byId('consentErr').textContent = '';
        }
        return first;
    }

    // ───────────── the message ─────────────
    function val(id) { return (byId(id).value || '').trim(); }

    function buildMessage() {
        var mods = [];
        form.querySelectorAll('input[name=modules]:checked').forEach(function (c) { mods.push(c.value); });
        var board = val('board') + (val('board') === 'State Board' && val('boardState') ? ' (' + val('boardState') + ')' : '');
        var lines = [];
        function add(label, value) { if (value) lines.push(label + ': ' + value); }

        lines.push('*NEW SCHOOL DETAILS*', '');
        lines.push('*School*');
        add('Institution', val('category')); add('School name', val('schoolName')); add('Short name', val('displayName'));
        add('Board', board); add('Affiliation / UDISE', val('affiliationNo')); add('Classes', val('schoolType'));
        add('Ownership', val('ownership')); add('Medium', val('medium')); add('Students (approx.)', val('students'));
        add('Session starts', val('sessionStart'));
        lines.push('', '*Trust / group*'); add('Name', val('orgName')); add('Other schools', val('otherSchools'));
        lines.push('', '*Address*'); add('Address', val('address')); add('City', val('city')); add('District', val('district'));
        add('State', val('state')); add('Pincode', val('pincode'));
        lines.push('', '*Main contact*'); add('Name', val('contactName')); add('Role', val('contactRole'));
        add('Mobile', val('contactPhone')); add('Email', val('contactEmail'));
        lines.push('', '*School Admin login*'); add('Name', val('adminName')); add('Email', val('adminEmail'));
        add('Mobile', val('adminPhone'));
        lines.push('', '*Wants*'); lines.push(mods.length ? mods.join(', ') : 'Not chosen');
        if (val('notes')) lines.push('', '*Notes*', val('notes'));
        return lines.join('\n');
    }

    var review = byId('onbReview');
    var out = byId('onbOut');
    var toast = byId('onbToast');
    var formErr = byId('formErr');

    form.addEventListener('submit', function (e) {
        e.preventDefault();
        var bad = validate();
        if (bad) {
            formErr.hidden = false;
            formErr.textContent = 'Some answers need fixing. They are marked in red.';
            bad.focus({ preventScroll: true });
            bad.scrollIntoView({ block: 'center', behavior: 'smooth' });
            return;
        }
        formErr.hidden = true;
        var msg = buildMessage();
        out.textContent = msg;
        byId('onbWaBtn').href = 'https://wa.me/' + sendTo + '?text=' + encodeURIComponent(msg);
        form.hidden = true;
        review.hidden = false;
        toast.textContent = '';
        review.scrollIntoView({ block: 'start' });
    });

    byId('onbEditBtn').addEventListener('click', function () {
        review.hidden = true;
        form.hidden = false;
        form.scrollIntoView({ block: 'start' });
    });

    byId('onbCopyBtn').addEventListener('click', function () {
        function done() { toast.textContent = 'Copied. Paste it into the WhatsApp chat.'; }
        function fallback() {
            var range = document.createRange();
            range.selectNodeContents(out);
            var sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            toast.textContent = 'Text selected. Use Copy from your phone menu.';
        }
        try { navigator.clipboard.writeText(out.textContent).then(done, fallback); } catch (e) { fallback(); }
    });

    // once a field is marked wrong, re-check as soon as the visitor leaves it
    form.querySelectorAll('input,select').forEach(function (el) {
        el.addEventListener('blur', function () { if (el.closest('.field.bad')) validate(); });
    });
})();
