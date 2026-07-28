// Please see documentation at https://docs.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Loaded on every page (Views/Shared/Sections/_Scripts.cshtml), after jQuery.

// Shared loaders. Rule for this app: never block the whole page — show the
// loader where the data is changing, so filters/pagination stay usable.
// Styles: wwwroot/css/site.css (.ec-top-loader).
var EC = window.EC || {};

// ── Top progress bar ────────────────────────────────────────────────────
// Thin bar at the top of the viewport, for background fetches.
// Created on first use, so pages need no markup.
EC.showLoader = function () {
    var $b = $('#ecTopLoader');
    if (!$b.length) $b = $('<div id="ecTopLoader" class="ec-top-loader"></div>').appendTo('body');
    $b.stop(true).css({ width: '0%', opacity: 1 }).animate({ width: '72%' }, 300);
};

EC.hideLoader = function () {
    $('#ecTopLoader').stop(true).animate({ width: '100%' }, 180, function () {
        $(this).delay(150).animate({ opacity: 0 }, 180, function () {
            $(this).css({ width: '0%', opacity: 1 });
        });
    });
};

// ── Button busy state ───────────────────────────────────────────────────
// For write actions (Save / Collect / Register). Disabling the clicked
// button is the only blocking needed — it stops the double-submit.
//
//     var $btn = $(this);
//     EC.buttonBusy($btn, 'Saving...');
//     $.post(url, data).always(function () { EC.buttonReset($btn); });
//
// The original button HTML is kept on the element itself (jQuery .data),
// so buttonReset can put it back.
EC.buttonBusy = function (btn, text) {
    var $b = $(btn);
    $b.data('ecOldHtml', $b.html());
    // Lock the width, otherwise an icon-only button shrinks while busy.
    $b.css('min-width', $b.outerWidth() + 'px')
      .prop('disabled', true)
      .html('<i class="bx bx-loader-circle bx-spin' + (text ? ' me-1' : '') + '"></i>' + (text || ''));
};

EC.buttonReset = function (btn) {
    var $b = $(btn);
    $b.css('min-width', '')
      .prop('disabled', false)
      .html($b.data('ecOldHtml'));
};

// ── Confirm / prompt dialogs ────────────────────────────────────────────
// Replace the native confirm() and prompt(). Built on the Bootstrap modal that
// is already loaded — no extra library.
//
// Shared shell for both. `fieldHtml` is dropped into the body (prompt uses it
// for the textarea); `readValue` turns the open dialog into the resolved value
// when the user confirms. Cancel always resolves `cancelValue`.
//
// NOTE the dispose()-then-remove order: removing the element straight away
// inside 'hidden.bs.modal' leaves Bootstrap's backdrop behind, and a stranded
// backdrop makes the whole page unclickable.
function ecDialog(opts, fieldHtml, readValue, cancelValue) {
    opts = opts || {};
    var danger = opts.danger !== false;
    var icon   = opts.icon   || (danger ? 'bx-trash' : 'bx-help-circle');
    var okText = opts.okText || (danger ? 'Delete' : 'Confirm');

    return new Promise(function (resolve) {
        // A dialog can still be on screen if the user double-clicked the button.
        // Ripping the element out on its own leaves Bootstrap's backdrop behind
        // and the page becomes unclickable, so dispose the old instance first
        // and sweep up a backdrop only when nothing else is actually showing.
        var existing = document.getElementById('ecConfirmModal');
        if (existing) {
            var prev = bootstrap.Modal.getInstance(existing);
            if (prev) prev.dispose();
            existing.remove();
            if (!document.querySelector('.modal.show')) {
                var strays = document.querySelectorAll('.modal-backdrop');
                for (var i = 0; i < strays.length; i++) strays[i].remove();
                document.body.classList.remove('modal-open');
                document.body.style.overflow = '';
                document.body.style.paddingRight = '';
            }
        }

        document.body.insertAdjacentHTML('beforeend',
            '<div class="modal fade ec-confirm" id="ecConfirmModal" tabindex="-1">' +
              '<div class="modal-dialog modal-dialog-centered modal-sm"><div class="modal-content">' +
                '<div class="modal-body text-center">' +
                  '<div class="ec-confirm-ic ' + (danger ? 'is-danger' : 'is-normal') + '">' +
                    '<i class="bx ' + icon + '"></i></div>' +
                  '<h5 class="ec-confirm-title">' + EC.esc(opts.title || 'Are you sure?') + '</h5>' +
                  (opts.name ? '<div class="ec-confirm-name">' + EC.esc(opts.name) + '</div>' : '') +
                  '<p class="ec-confirm-msg">' + EC.esc(opts.message || '') + '</p>' +
                  (fieldHtml || '') +
                '</div>' +
                '<div class="modal-footer">' +
                  '<button type="button" class="btn btn-label-secondary flex-fill" data-bs-dismiss="modal">Cancel</button>' +
                  '<button type="button" class="btn flex-fill ec-confirm-yes ' +
                    (danger ? 'is-danger' : 'is-normal') + '">' + EC.esc(okText) + '</button>' +
                '</div>' +
              '</div></div></div>');

        var el     = document.getElementById('ecConfirmModal');
        var modal  = new bootstrap.Modal(el);
        var yes    = el.querySelector('.ec-confirm-yes');
        var field  = el.querySelector('.ec-confirm-input');
        var result = cancelValue;

        // Required field: keep the confirm button dead until something is typed,
        // so a blank reason can never reach the audit trail.
        if (field && opts.required) {
            yes.disabled = true;
            field.addEventListener('input', function () {
                yes.disabled = field.value.trim().length === 0;
            });
        }
        if (field) el.addEventListener('shown.bs.modal', function () { field.focus(); });

        yes.addEventListener('click', function () {
            result = readValue(el);
            modal.hide();
        });
        el.addEventListener('hidden.bs.modal', function () {
            modal.dispose();
            setTimeout(function () { el.remove(); resolve(result); }, 0);
        });
        modal.show();
    });
}

// Returns Promise<boolean>.
//
//     EC.confirm({
//         title:   'Delete this class?',
//         name:    'Class 5 — 3 sections',      // optional, shown highlighted
//         message: 'This cannot be undone.',
//         okText:  'Delete class'
//     }).then(function (ok) {
//         if (!ok) return;
//         deleteClass(id);
//     });
//
// danger defaults to true (red button, trash icon) because almost every
// confirmation in this app guards a delete. Pass danger:false for the rest.
EC.confirm = function (opts) {
    return ecDialog(opts, '', function () { return true; }, false);
};

// Returns Promise<string|null> — null when cancelled, otherwise the trimmed
// text. With required:true the confirm button stays disabled until the user
// types something, which the native prompt() could not do: it only told you
// about Cancel, so an empty reason went through as a valid answer.
//
//     EC.prompt({
//         title:    'Void this certificate?',
//         name:     'TC-2026-0007',
//         label:    'Reason',
//         required: true,
//         okText:   'Void certificate'
//     }).then(function (reason) {
//         if (reason === null) return;
//         voidTc(id, reason);
//     });
EC.prompt = function (opts) {
    opts = opts || {};
    var html =
        '<div class="ec-confirm-field">' +
          (opts.label ? '<label class="ec-confirm-label">' + EC.esc(opts.label) +
                        (opts.required ? ' <span class="text-danger">*</span>' : '') + '</label>' : '') +
          '<textarea class="form-control ec-confirm-input" rows="2" maxlength="' +
            (opts.maxLength || 300) + '" placeholder="' + EC.esc(opts.placeholder || '') + '"></textarea>' +
        '</div>';

    return ecDialog(opts, html, function (el) {
        return el.querySelector('.ec-confirm-input').value.trim();
    }, null);
};

// Markup-only shortcut for the common "form that deletes something" case, so a
// plain Razor form needs no page script at all:
//
//     <form asp-action="Delete" method="post"
//           data-ec-confirm="Delete this role?"
//           data-ec-confirm-name="@r.RoleName"
//           data-ec-confirm-ok="Delete role"> … </form>
//
// Capture phase so this runs before the double-submit guard further down in
// _Scripts.cshtml — that guard skips a submit whose default was prevented, so
// the button is not left disabled when the user picks Cancel.
document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form || form.tagName !== 'FORM' || !form.hasAttribute('data-ec-confirm')) return;
    if (form.getAttribute('data-ec-confirmed') === '1') return;   // second pass: let it go

    e.preventDefault();
    EC.confirm({
        title:   form.getAttribute('data-ec-confirm'),
        name:    form.getAttribute('data-ec-confirm-name') || '',
        message: form.getAttribute('data-ec-confirm-message') || '',
        okText:  form.getAttribute('data-ec-confirm-ok') || ''
    }).then(function (ok) {
        if (!ok) return;
        form.setAttribute('data-ec-confirmed', '1');
        form.submit();
    });
}, true);

// ── HTML escaping ───────────────────────────────────────────────────────
// Run every value that comes from the database through this before putting it
// into an HTML string, e.g.  '<td>' + EC.esc(r.studentName) + '</td>'.
// Without it a student named "<script>…" would execute when the list renders.
//
// The project had four different esc() copies; some skipped the null guard
// (printing a literal "null" on screen) and some skipped the single quote.
// This is the strict one — use it everywhere.
EC.esc = function (s) {
    return (s === null || s === undefined ? '' : String(s))
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
};

// ── Money ───────────────────────────────────────────────────────────────
// Indian grouping, always two decimals:  1234.56 -> ₹1,234.56   1200 -> ₹1,200.00
//
// Always two decimals on purpose. The project had two copies of this, one that
// rounded to whole rupees and one that did not, so the same amount printed
// differently on the fee screens and the inventory screens. Rounding also hides
// paise from the person counting cash, so the exact figure wins.
EC.money = function (n) {
    return '₹' + Number(n || 0).toLocaleString('en-IN', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    });
};

// ── Numbers ─────────────────────────────────────────────────────────────
// Safe Number(): anything unparseable becomes 0, so arithmetic never turns
// into NaN and prints "₹NaN" on screen.
//
// Two names on purpose. The project had ONE function called num() with two
// different bodies — one kept negatives, one clamped them to 0 — so copying a
// line between pages silently changed the maths.
//
//   EC.num    keeps negatives. Use for arithmetic results, e.g. a cash
//             reconciliation difference that is legitimately short.
//   EC.numPos clamps negatives to 0. Use when reading a money amount the user
//             typed, so a "-500" cannot flow into a payable or a tender.
EC.num = function (v) {
    var n = Number(v);
    return isFinite(n) ? n : 0;
};

EC.numPos = function (v) {
    var n = Number(v);
    return isFinite(n) && n > 0 ? n : 0;
};

// ── List states ─────────────────────────────────────────────────────────
// A full-width message row inside a list. Pass a <tbody> and the colspan is
// read off the table's own header; any other container works too.
EC.listState = function (target, inner) {
    var $t = $(target);
    if ($t.is('tbody')) {
        var cols = $t.closest('table').find('thead tr').first().children().length || 1;
        $t.html('<tr><td colspan="' + cols + '" class="text-center py-5 text-muted">' + inner + '</td></tr>');
    } else {
        $t.html('<div class="text-center py-5 text-muted">' + inner + '</div>');
    }
};

EC.listLoading = function (target, text) {
    EC.listState(target,
        '<div class="spinner-border spinner-border-sm text-primary me-2"></div>' + (text || 'Loading...'));
};

// Call this on every path where no rows will arrive — empty result, an
// error response, or a failed request. Without it the spinner keeps
// turning and the user thinks the page is still loading.
EC.listEmpty = function (target, text, icon) {
    EC.listState(target,
        // mx-auto is needed: bx icons have a fixed width, so d-block alone
        // parks the box on the left even though the text is centred.
        '<i class="bx ' + (icon || 'bx-search-alt') + ' d-block mx-auto mb-2" style="font-size:2rem;opacity:.35"></i>' +
        (text || 'No data found'));
};

window.EC = EC;
