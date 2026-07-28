/* =========================================================================
   EcReceipt — shared fee-receipt renderer.

   Requires the _FeeReceiptModal partial on the page (#ecReceiptModal,
   #ecReceiptPaper, #ecReceiptPrintBtn). Fetches the authoritative receipt from
   /ERP/Fee/GetReceipt and renders it in the school's chosen PRINT FORMAT:

     A4      full page + letterhead, School / Parent copy   (office record)
     A5      compact half page, two fit on one A4 sheet     (daily counter)
     Thermal 80mm roll, monospaced                          (POS printer)

   The format comes from the server (school setting), so every screen prints the
   same way without each page deciding for itself.

     EcReceipt.show('RCP-2026-0007');
========================================================================= */
(function (window, $) {
    'use strict';

    var ENDPOINT = '/ERP/Fee/GetReceipt';


    function fmtDate(d) {
        if (!d) return '-';
        var x = new Date(d);
        if (isNaN(x)) return d;
        var M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        return String(x.getDate()).padStart(2, '0') + ' ' + M[x.getMonth()] + ' ' + x.getFullYear();
    }

    /* Amount in words, Indian system (lakh / crore) — standard on fee receipts. */
    var ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
                'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
    var TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

    function twoDigits(n) {
        if (n < 20) return ONES[n];
        return TENS[Math.floor(n / 10)] + (n % 10 ? ' ' + ONES[n % 10] : '');
    }
    function inWords(num) {
        num = Math.floor(Math.abs(Number(num) || 0));
        if (num === 0) return 'Zero';
        var out = '';
        var crore = Math.floor(num / 10000000); num %= 10000000;
        var lakh  = Math.floor(num / 100000);   num %= 100000;
        var thou  = Math.floor(num / 1000);     num %= 1000;
        var hund  = Math.floor(num / 100);      num %= 100;
        if (crore) out += twoDigits(crore) + ' Crore ';
        if (lakh)  out += twoDigits(lakh)  + ' Lakh ';
        if (thou)  out += twoDigits(thou)  + ' Thousand ';
        if (hund)  out += ONES[hund] + ' Hundred ';
        if (num)   out += (out ? 'and ' : '') + twoDigits(num) + ' ';
        return out.trim();
    }
    function amountWords(amount) {
        var whole = Math.floor(Math.abs(Number(amount) || 0));
        var paise = Math.round((Math.abs(Number(amount) || 0) - whole) * 100);
        var s = 'Rupees ' + inWords(whole);
        if (paise > 0) s += ' and ' + twoDigits(paise) + ' Paise';
        return s + ' Only';
    }

    /* ---------- shared pieces ---------- */

    // Fee particulars. `compact` drops the per-line waiver note (no room on 80mm).
    function lineRows(r, compact) {
        return (r.lines || []).map(function (l, i) {
            var extra  = l.lineType === 'Extra' ? ' <span class="rc-muted">(extra)</span>' : '';
            var waived = (!compact && l.concession > 0)
                ? ' <span class="rc-muted">(−' + EC.money(l.concession) + ' waived)</span>' : '';
            return '<tr>' +
                   (compact ? '' : '<td class="rc-sn">' + (i + 1) + '</td>') +
                   '<td>' + EC.esc(l.label) + extra + waived + '</td>' +
                   '<td class="rc-amt">' + EC.money(l.amount) + '</td></tr>';
        }).join('');
    }

    // Deductions / adjustments that change what was actually taken.
    function adjustmentRows(r, cols) {
        var out = '';
        if (r.concession > 0) {
            var lbl = 'Concession' +
                (r.discountType === 'Percent' ? ' (' + r.discountValue + '%)' : '') +
                (r.discountReason ? ' <span class="rc-muted">' + EC.esc(r.discountReason) + '</span>' : '');
            out += '<tr><td colspan="' + cols + '">' + lbl + '</td><td class="rc-amt">−' + EC.money(r.concession) + '</td></tr>';
        }
        if (r.advanceUsed > 0)
            out += '<tr><td colspan="' + cols + '">Paid from advance</td><td class="rc-amt">−' + EC.money(r.advanceUsed) + '</td></tr>';
        if (r.advanceCredit > 0)
            out += '<tr><td colspan="' + cols + '">Saved to advance</td><td class="rc-amt">+' + EC.money(r.advanceCredit) + '</td></tr>';
        return out;
    }

    function title(r) {
        return r.paymentType === 'Registration' ? 'REGISTRATION FEE RECEIPT' : 'FEE RECEIPT';
    }

    // School logo for the letterhead. The server sends an ABSOLUTE url because the
    // print popup has no base to resolve a relative path against. onerror hides the
    // slot so a missing/broken file never leaves a blank box on the receipt.
    function logoImg(sch, cls) {
        if (!sch || !sch.logo) return '';
        return '<img class="' + cls + '" src="' + EC.esc(sch.logo) + '" alt="" ' +
               'onerror="this.style.display=\'none\'" />';
    }

    /* ---------- A4: full page, letterhead, School + Parent copy ---------- */
    function renderA4(r, copyLabel) {
        var sch = r.school || {}, stu = r.student || {};
        var cls = (stu.className || '-') + (stu.section ? ' - ' + stu.section : '');
        return '' +
        '<div class="rc rc-a4">' +
          '<div class="rc-head">' +
            '<div class="rc-lettermark">' +
              logoImg(sch, 'rc-logo') +
              '<div class="rc-lettertext">' +
                '<div class="rc-school">' + EC.esc(sch.name || 'School') + '</div>' +
                (sch.address ? '<div class="rc-addr">' + EC.esc(sch.address) + '</div>' : '') +
              '</div>' +
            '</div>' +
            '<div class="rc-title">' + title(r) + '</div>' +
            (copyLabel ? '<div class="rc-copy">' + copyLabel + '</div>' : '') +
          '</div>' +

          '<div class="rc-meta">' +
            '<div><span>Receipt No</span><b>' + EC.esc(r.receiptNo) + '</b></div>' +
            '<div><span>Date</span><b>' + fmtDate(r.date) + '</b></div>' +
          '</div>' +

          '<table class="rc-info">' +
            '<tr><td><span>Student</span><b>' + EC.esc(stu.name || '-') + '</b></td>' +
                '<td><span>Adm / Reg No</span><b>' + EC.esc(stu.admNo || '-') + '</b></td></tr>' +
            '<tr><td><span>Class</span><b>' + EC.esc(cls) + '</b></td>' +
                '<td><span>Roll No</span><b>' + EC.esc(stu.roll || '-') + '</b></td></tr>' +
          '</table>' +

          '<table class="rc-lines">' +
            '<thead><tr><th class="rc-sn">#</th><th>Particulars</th><th class="rc-amt">Amount</th></tr></thead>' +
            '<tbody>' + lineRows(r, false) + adjustmentRows(r, 2) + '</tbody>' +
            '<tfoot><tr><td colspan="2">Total Paid</td><td class="rc-amt">' + EC.money(r.amount) + '</td></tr></tfoot>' +
          '</table>' +

          '<div class="rc-words"><span>In words:</span> ' + EC.esc(amountWords(r.amount)) + '</div>' +

          '<div class="rc-pay">' +
            '<div><span>Mode</span><b>' + EC.esc(r.mode || '-') + (r.reference ? ' · ' + EC.esc(r.reference) : '') + '</b></div>' +
            (r.remarks ? '<div><span>Note</span><b>' + EC.esc(r.remarks) + '</b></div>' : '') +
          '</div>' +

          '<div class="rc-sign">' +
            '<div class="rc-sign-box"><div class="rc-line"></div>Cashier</div>' +
            '<div class="rc-sign-box"><div class="rc-line"></div>Authorised Signatory</div>' +
          '</div>' +
          '<div class="rc-foot">System-generated receipt. Please retain for your records.</div>' +
        '</div>';
    }

    /* ---------- A5: compact, two per A4 sheet ---------- */
    function renderA5(r) {
        var sch = r.school || {}, stu = r.student || {};
        var cls = (stu.className || '-') + (stu.section ? ' - ' + stu.section : '');
        return '' +
        '<div class="rc rc-a5">' +
          '<div class="rc-head">' +
            '<div class="rc-lettermark">' +
              logoImg(sch, 'rc-logo') +
              '<div class="rc-lettertext">' +
                '<div class="rc-school">' + EC.esc(sch.name || 'School') + '</div>' +
                (sch.address ? '<div class="rc-addr">' + EC.esc(sch.address) + '</div>' : '') +
              '</div>' +
            '</div>' +
            '<div class="rc-title">' + title(r) + '</div>' +
          '</div>' +
          '<div class="rc-meta">' +
            '<div><span>Receipt</span><b>' + EC.esc(r.receiptNo) + '</b></div>' +
            '<div><span>Date</span><b>' + fmtDate(r.date) + '</b></div>' +
          '</div>' +
          '<div class="rc-inline">' +
            '<b>' + EC.esc(stu.name || '-') + '</b> · ' + EC.esc(stu.admNo || '-') + ' · ' + EC.esc(cls) +
          '</div>' +
          '<table class="rc-lines">' +
            '<tbody>' + lineRows(r, true) + adjustmentRows(r, 1) + '</tbody>' +
            '<tfoot><tr><td>Total Paid</td><td class="rc-amt">' + EC.money(r.amount) + '</td></tr></tfoot>' +
          '</table>' +
          '<div class="rc-words">' + EC.esc(amountWords(r.amount)) + '</div>' +
          '<div class="rc-pay"><div><span>Mode</span><b>' + EC.esc(r.mode || '-') +
              (r.reference ? ' · ' + EC.esc(r.reference) : '') + '</b></div></div>' +
          '<div class="rc-sign"><div class="rc-sign-box"><div class="rc-line"></div>Cashier</div></div>' +
        '</div>';
    }

    /* ---------- Thermal: 80mm roll ---------- */
    function renderThermal(r) {
        var sch = r.school || {}, stu = r.student || {};
        var cls = (stu.className || '-') + (stu.section ? ' - ' + stu.section : '');
        return '' +
        '<div class="rc rc-th">' +
          '<div class="rc-head">' +
            logoImg(sch, 'rc-logo') +
            '<div class="rc-school">' + EC.esc(sch.name || 'School') + '</div>' +
            (sch.address ? '<div class="rc-addr">' + EC.esc(sch.address) + '</div>' : '') +
            '<div class="rc-title">' + title(r) + '</div>' +
          '</div>' +
          '<div class="rc-sep"></div>' +
          '<div class="rc-kv"><span>Receipt</span><b>' + EC.esc(r.receiptNo) + '</b></div>' +
          '<div class="rc-kv"><span>Date</span><b>' + fmtDate(r.date) + '</b></div>' +
          '<div class="rc-kv"><span>Student</span><b>' + EC.esc(stu.name || '-') + '</b></div>' +
          '<div class="rc-kv"><span>Adm No</span><b>' + EC.esc(stu.admNo || '-') + '</b></div>' +
          '<div class="rc-kv"><span>Class</span><b>' + EC.esc(cls) + '</b></div>' +
          '<div class="rc-sep"></div>' +
          '<table class="rc-lines"><tbody>' + lineRows(r, true) + adjustmentRows(r, 1) + '</tbody></table>' +
          '<div class="rc-sep"></div>' +
          '<div class="rc-kv rc-tot"><span>TOTAL</span><b>' + EC.money(r.amount) + '</b></div>' +
          '<div class="rc-kv"><span>Mode</span><b>' + EC.esc(r.mode || '-') + '</b></div>' +
          (r.reference ? '<div class="rc-kv"><span>Ref</span><b>' + EC.esc(r.reference) + '</b></div>' : '') +
          '<div class="rc-sep"></div>' +
          '<div class="rc-words">' + EC.esc(amountWords(r.amount)) + '</div>' +
          '<div class="rc-foot">Thank you.<br/>System-generated receipt.</div>' +
        '</div>';
    }

    /* ---------- print styles per format ---------- */
    function styles(format) {
        var base =
        '*{box-sizing:border-box}' +
        'body{margin:0;font-family:"Segoe UI",Arial,sans-serif;color:#111}' +
        '.rc{background:#fff}' +
        '.rc-head{text-align:center}' +
        '.rc-school{font-weight:700;letter-spacing:.3px}' +
        '.rc-addr{color:#555}' +
        '.rc-title{font-weight:700;letter-spacing:1px}' +
        '.rc-muted{color:#888;font-weight:400}' +
        '.rc-amt{text-align:right;white-space:nowrap}' +
        '.rc-lines{width:100%;border-collapse:collapse}' +
        '.rc-lines td,.rc-lines th{padding:4px 6px;vertical-align:top}' +
        '.rc-lines tfoot td{font-weight:700;border-top:1px solid #000}' +
        '.rc-words{font-style:italic}' +
        '.rc-foot{text-align:center;color:#777}' +
        // Letterhead: logo beside the school name on paper formats, above it on 80mm.
        '.rc-lettermark{display:flex;align-items:center;justify-content:center;gap:10px}' +
        '.rc-lettertext{text-align:center}' +
        '.rc-logo{object-fit:contain;flex:0 0 auto}';

        if (format === 'Thermal') {
            return base +
            '@page{size:80mm auto;margin:3mm}' +
            '.rc-th{width:72mm;font-family:"Courier New",monospace;font-size:11px;line-height:1.35}' +
            '.rc-th .rc-logo{max-height:12mm;max-width:40mm;margin:0 auto 2px;display:block;filter:grayscale(1) contrast(1.3)}' +
            '.rc-th .rc-school{font-size:13px}' +
            '.rc-th .rc-addr,.rc-th .rc-title{font-size:10px}' +
            '.rc-th .rc-title{margin-top:2px}' +
            '.rc-sep{border-top:1px dashed #000;margin:4px 0}' +
            '.rc-kv{display:flex;justify-content:space-between;gap:6px}' +
            '.rc-kv b{font-weight:700;text-align:right}' +
            '.rc-tot{font-size:13px;font-weight:700}' +
            '.rc-th .rc-lines td{padding:1px 0;font-size:11px}' +
            '.rc-th .rc-words{font-size:10px;margin-top:2px}' +
            '.rc-th .rc-foot{font-size:10px;margin-top:6px}';
        }
        if (format === 'A5') {
            return base +
            '@page{size:A5;margin:8mm}' +
            '.rc-a5{width:100%;font-size:12px}' +
            '.rc-a5 .rc-logo{max-height:13mm;max-width:26mm}' +
            '.rc-a5 .rc-school{font-size:16px}' +
            '.rc-a5 .rc-title{font-size:11px;margin-top:2px}' +
            '.rc-meta{display:flex;justify-content:space-between;margin:6px 0;padding:4px 0;border-top:1px solid #000;border-bottom:1px solid #000}' +
            '.rc-meta span{color:#666;margin-right:4px}' +
            '.rc-inline{margin-bottom:6px}' +
            '.rc-a5 .rc-lines td{border-bottom:1px dotted #ccc}' +
            '.rc-pay{margin-top:6px}.rc-pay span{color:#666;margin-right:4px}' +
            '.rc-sign{margin-top:18px;display:flex;justify-content:flex-end}' +
            '.rc-sign-box{text-align:center;font-size:10px;color:#555}' +
            '.rc-line{width:120px;border-top:1px solid #000;margin-bottom:2px}';
        }
        // A4 (default)
        return base +
        '@page{size:A4;margin:12mm}' +
        '.rc-a4{width:100%;font-size:13px}' +
        '.rc-a4 .rc-head{border-bottom:2px solid #000;padding-bottom:8px}' +
        '.rc-a4 .rc-logo{max-height:20mm;max-width:36mm}' +
        '.rc-a4 .rc-school{font-size:22px}' +
        '.rc-a4 .rc-addr{font-size:11px;margin-top:2px}' +
        '.rc-a4 .rc-title{font-size:13px;margin-top:6px}' +
        '.rc-copy{font-size:10px;color:#666;margin-top:2px}' +
        '.rc-meta{display:flex;justify-content:space-between;margin:10px 0}' +
        '.rc-meta span{display:block;color:#666;font-size:10px}' +
        '.rc-info{width:100%;border-collapse:collapse;margin-bottom:10px}' +
        '.rc-info td{padding:4px 0;width:50%}' +
        '.rc-info span{display:block;color:#666;font-size:10px}' +
        '.rc-a4 .rc-lines th{background:#f2f2f2;border-bottom:1px solid #000;text-align:left}' +
        '.rc-a4 .rc-lines td{border-bottom:1px solid #eee}' +
        '.rc-sn{width:32px}' +
        '.rc-words{margin-top:8px;font-size:12px}' +
        '.rc-words span{color:#666;font-style:normal}' +
        '.rc-pay{margin-top:8px;display:flex;gap:24px;font-size:12px}' +
        '.rc-pay span{display:block;color:#666;font-size:10px}' +
        '.rc-sign{margin-top:34px;display:flex;justify-content:space-between}' +
        '.rc-sign-box{text-align:center;font-size:11px;color:#555}' +
        '.rc-line{width:150px;border-top:1px solid #000;margin-bottom:3px}' +
        '.rc-foot{margin-top:14px;font-size:10px}' +
        '.rc-cut{border-top:1px dashed #999;margin:16px 0}';
    }

    function buildHtml(r) {
        var f = r.format || 'A4';
        if (f === 'Thermal') return renderThermal(r);
        if (f === 'A5')      return renderA5(r);
        // A4 prints School + Parent copy on one page (standard counterfoil practice).
        return renderA4(r, 'School Copy') + '<div class="rc-cut"></div>' + renderA4(r, 'Parent Copy');
    }

    var current = null;   // last loaded receipt, so Print reuses the same data

    function render(r) {
        current = r;
        var f = (r && r.format) || 'A4';
        // Preview inside the modal uses the same markup + styles as the print.
        $('#ecReceiptPaper').html('<style>' + styles(f) + '</style>' + buildHtml(r));
    }

    function printCurrent() {
        if (!current) return;
        var f = current.format || 'A4';
        var w = window.open('', '_blank', 'width=460,height=680');
        if (!w) { ecToast('error', 'Allow pop-ups to print the receipt.'); return; }
        w.document.write('<html><head><title>' + EC.esc(current.receiptNo || 'Receipt') + '</title>' +
                         '<style>' + styles(f) + '</style></head><body>' + buildHtml(current) + '</body></html>');
        w.document.close();
        w.focus();
        // Give the new window a tick to lay out before printing.
        setTimeout(function () { w.print(); }, 150);
    }

    // Opens the receipt in the school's saved format. To print it in another format
    // once, use the A4 / A5 / Thermal buttons in the modal (see setFormat below).
    function show(receiptNo) {
        if (!receiptNo) return;
        $.getJSON(ENDPOINT, { receiptNo: receiptNo })
            .done(function (r) {
                if (!r) { ecToast('error', 'Receipt not found.'); return; }
                render(r);
                var el = document.getElementById('ecReceiptModal');
                if (!el) return;
                // The modal is shared with preview(), which relabels/resizes it.
                $(el).find('.modal-title').text('Payment Receipt');
                $(el).find('.modal-dialog').removeClass('modal-lg');
                if (window.bootstrap) new window.bootstrap.Modal(el).show();
            })
            .fail(function () { ecToast('error', 'Could not load the receipt.'); });
    }

    // Load + print without opening the preview (list "Print" buttons).
    function print(receiptNo) {
        if (!receiptNo) return;
        $.getJSON(ENDPOINT, { receiptNo: receiptNo })
            .done(function (r) {
                if (!r) { ecToast('error', 'Receipt not found.'); return; }
                current = r;
                printCurrent();
            })
            .fail(function () { ecToast('error', 'Could not load the receipt.'); });
    }

    $(function () {
        $(document).on('click', '#ecReceiptPrintBtn', printCurrent);
    });

    /* ---------- format preview (School Settings) ----------
       Renders a SAMPLE receipt in the given format using the school's own
       letterhead, so the setting can be judged before it is saved. No server
       round-trip and nothing is recorded — this is a mock receipt. */
    function sampleReceipt(format, school) {
        return {
            format: format || 'A4',
            school: school || { name: 'Your School', address: '' },
            receiptNo: 'RCP-0000-0000',
            date: new Date().toISOString().slice(0, 10),
            amount: 7001,
            concession: 250,
            discountType: 'Flat',
            discountReason: 'Sibling discount',
            mode: 'Cash',
            reference: '',
            paymentType: 'Fee',
            advanceUsed: 0,
            advanceCredit: 0,
            remarks: 'Sample receipt — preview only.',
            student: { name: 'Aarav Sharma', admNo: 'ADM-0000-0001', className: 'Nursery', section: 'A', roll: '12' },
            lines: [
                { label: 'Admission Fee', amount: 5000, concession: 0, lineType: 'Due' },
                { label: 'Security Deposit', amount: 2001, concession: 0, lineType: 'Due' },
                { label: 'Tuition Fee — Apr 2027', amount: 250, concession: 250, lineType: 'Due' }
            ]
        };
    }

    function preview(format, school) {
        render(sampleReceipt(format, school));
        var el = document.getElementById('ecReceiptModal');
        if (!el) { ecToast('error', 'Preview is not available on this page.'); return; }
        // Label it a preview and give A4 room to breathe; show() resets both when a
        // real receipt is opened in the same shared modal.
        $(el).find('.modal-title').text('Receipt preview — ' + (format || 'A4'));
        $(el).find('.modal-dialog').toggleClass('modal-lg', (format || 'A4') !== 'Thermal');
        if (window.bootstrap) new window.bootstrap.Modal(el).show();
    }

    // Re-draw the open receipt in another format. The modal's A4 / A5 / Thermal
    // buttons call this; it only changes what is on screen, not the school setting.
    function setFormat(format) {
        if (!current) return;
        current.format = format;
        render(current);
    }

    window.EcReceipt = { show: show, print: print, render: render, preview: preview, setFormat: setFormat };

})(window, jQuery);
