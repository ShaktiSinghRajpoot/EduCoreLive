/* =========================================================================
   EcReceipt — shared fee-receipt renderer.
   Requires the _FeeReceiptModal partial on the page (provides #ecReceiptModal,
   #ecReceiptPaper, #ecReceiptPrintBtn). Works in any area: it fetches the
   authoritative receipt from /ERP/Fee/GetReceipt and renders + prints it.

     EcReceipt.show('RCP-2026-0007');

========================================================================= */
(function (window, $) {
    'use strict';

    var ENDPOINT = '/ERP/Fee/GetReceipt';

    function money(n) { return '₹' + Math.round(Number(n || 0)).toLocaleString('en-IN'); }
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
        });
    }
    function notify(type, msg) { if (typeof toastr !== 'undefined') toastr[type](msg); }

    function render(r) {
        var sch = r.school || { name: 'Your School', address: '' };
        var lines = (r.lines || []).map(function (l) {
            var label = esc(l.label) +
                (l.lineType === 'Extra' ? ' <small style="color:#888">(extra)</small>' : '') +
                (l.concession > 0 ? ' <small style="color:#888">(−' + money(l.concession) + ' waived)</small>' : '');
            return '<tr class="r-line"><td>' + label + '</td><td style="text-align:right">' + money(l.amount) + '</td></tr>';
        }).join('');

        var discLabel = r.discountReason
            ? 'Discount' + (r.discountType === 'Percent' ? ' (' + r.discountValue + '%)' : '') +
                ' <small style="color:#888">' + esc(r.discountReason) + '</small>'
            : 'Concession';
        var concRow = r.concession > 0
            ? '<tr><td>' + discLabel + '</td><td style="text-align:right">−' + money(r.concession) + '</td></tr>' : '';

        var advUsedRow = r.advanceUsed > 0
            ? '<tr><td>Paid from advance</td><td style="text-align:right">−' + money(r.advanceUsed) + '</td></tr>' : '';
        var advCreditRow = r.advanceCredit > 0
            ? '<tr><td style="color:#1f9254">Saved to advance</td><td style="text-align:right;color:#1f9254">+' + money(r.advanceCredit) + '</td></tr>' : '';

        var stu = r.student || {};
        var classLine = (stu.className || '-') + (stu.section ? ' - ' + stu.section : '');

        $('#ecReceiptPaper').html(
            '<div class="r-school"><h5>' + esc(sch.name) + '</h5>' +
              (sch.address ? '<small>' + esc(sch.address) + '</small><br>' : '') +
              '<small>' + (r.paymentType === 'Registration' ? 'Registration Fee Receipt' : 'Fee Payment Receipt') + '</small></div>' +
            '<table style="margin-bottom:.5rem">' +
              '<tr><td>Receipt No</td><td style="text-align:right"><strong>' + esc(r.receiptNo) + '</strong></td></tr>' +
              '<tr><td>Date</td><td style="text-align:right">' + esc(r.date || '-') + '</td></tr>' +
              '<tr><td>Name</td><td style="text-align:right">' + esc(stu.name || '-') +
                  (stu.admNo && stu.admNo !== '-' ? ' (' + esc(stu.admNo) + ')' : '') + '</td></tr>' +
              '<tr><td>Class</td><td style="text-align:right">' + esc(classLine) + '</td></tr>' +
              '<tr><td>Mode</td><td style="text-align:right">' + esc(r.mode || '-') +
                  (r.reference ? ' (' + esc(r.reference) + ')' : '') + '</td></tr>' +
            '</table>' +
            '<table>' + lines + concRow +
              '<tr class="r-total"><td>Total Paid</td><td style="text-align:right">' + money(r.amount) + '</td></tr>' +
              advUsedRow + advCreditRow +
            '</table>' +
            (r.remarks ? '<p style="margin-top:.5rem;font-size:.78rem;color:#666">Note: ' + esc(r.remarks) + '</p>' : '') +
            '<p style="text-align:center;margin-top:.8rem;font-size:.75rem;color:#888">Thank you. This is a system-generated receipt.</p>'
        );
    }

    function show(receiptNo) {
        if (!receiptNo) return;
        $.getJSON(ENDPOINT, { receiptNo: receiptNo })
            .done(function (r) {
                if (!r) { notify('error', 'Receipt not found.'); return; }
                render(r);
                var el = document.getElementById('ecReceiptModal');
                if (el && window.bootstrap) new window.bootstrap.Modal(el).show();
            })
            .fail(function () { notify('error', 'Could not load the receipt.'); });
    }

    $(function () {
        $(document).on('click', '#ecReceiptPrintBtn', function () {
            var html = document.getElementById('ecReceiptPaper').innerHTML;
            var w = window.open('', '_blank', 'width=420,height=640');
            w.document.write('<html><head><title>Receipt</title></head><body>' + html + '</body></html>');
            w.document.close(); w.focus(); w.print();
        });
    });

    window.EcReceipt = { show: show, render: render };

})(window, jQuery);
