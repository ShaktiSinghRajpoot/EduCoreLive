// Student profile > Parent Access card (Parent App, Database/parent_module.sql).
// Lists the student's mobiles with their last parent login, and lets staff with
// students.manage block one mobile from this child (Block / Unblock).
// The card carries its own urls and the student's uuid in data- attributes.
(function () {
    'use strict';

    var card = document.getElementById('parentAccessCard');
    if (!card) { return; }

    var STUDENT_ID = card.getAttribute('data-student');
    var CAN_MANAGE = card.getAttribute('data-can-manage') === '1';
    var GET_URL    = card.getAttribute('data-get-url');
    var BLOCK_URL  = card.getAttribute('data-block-url');
    var CSRF       = $(card).find('input[name="__RequestVerificationToken"]').val();
    var BODY       = '#parentAccessBody';

    function render(rows) {
        if (!rows || !rows.length) {
            EC.listEmpty(BODY, 'No 10-digit mobile number on this record, so no parent can log in.', 'bx-mobile');
            return;
        }
        var html = '';
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            var status = r.blocked
                ? '<span class="badge bg-label-danger">Blocked</span>'
                : '<span class="badge bg-label-success">Allowed</span>';
            var button = '';
            if (CAN_MANAGE) {
                button = '<button type="button" class="btn btn-sm ' + (r.blocked ? 'btn-outline-primary' : 'btn-outline-danger') +
                         ' pa-block-btn" data-mobile="' + EC.esc(r.mobile) + '" data-block="' + (r.blocked ? '0' : '1') + '">' +
                         (r.blocked ? 'Unblock' : 'Block') + '</button>';
            }
            html += '<tr>' +
                    '<td>' + EC.esc(r.mobile) + '<div class="text-muted small">' + EC.esc(r.label) + '</div></td>' +
                    '<td>' + (r.lastLogin ? EC.esc(r.lastLogin) : '<span class="text-muted">Never</span>') + '</td>' +
                    '<td>' + status + '</td>' +
                    '<td class="text-end">' + button + '</td>' +
                    '</tr>';
        }
        $(BODY).html(html);
    }

    function load() {
        EC.listLoading(BODY);
        $.get(GET_URL, { id: STUDENT_ID })
            .done(function (d) {
                if (!d || !d.success) {
                    EC.listEmpty(BODY, (d && d.message) || 'Could not load.', 'bx-error-circle');
                    return;
                }
                render(d.rows);
            })
            .fail(function () {
                EC.listEmpty(BODY, 'Could not load. Please retry.', 'bx-error-circle');
            });
    }

    function save($btn, mobile, block) {
        EC.buttonBusy($btn, block ? 'Blocking…' : 'Unblocking…');
        $.ajax({
            url: BLOCK_URL,
            type: 'POST',
            contentType: 'application/json',
            headers: { 'RequestVerificationToken': CSRF },
            data: JSON.stringify({ id: STUDENT_ID, mobile: mobile, block: block })
        })
            .done(function (d) {
                if (!d || !d.success) {
                    ecToast('error', (d && d.message) || 'Could not save.');
                    return;
                }
                ecToast('success', d.message);
                render(d.rows);
            })
            .fail(function () {
                ecToast('error', 'Could not save. Please retry.');
            })
            .always(function () {
                EC.buttonReset($btn);
            });
    }

    $(document).on('click', '#parentAccessCard .pa-block-btn', function () {
        var $btn = $(this);
        var mobile = $btn.attr('data-mobile');
        var block = $btn.attr('data-block') === '1';
        if (!block) {
            save($btn, mobile, false);
            return;
        }
        EC.confirm({
            title: 'Block this mobile?',
            name: mobile,
            message: 'This mobile will no longer see this child in the Parent App. The student record is not changed, and other children of this mobile are not affected.',
            okText: 'Block'
        }).then(function (ok) {
            if (ok) { save($btn, mobile, true); }
        });
    });

    load();
})();
