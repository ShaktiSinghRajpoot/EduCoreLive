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

// ── PWA install ─────────────────────────────────────────────────────────
// Drives the "Install App" item in the sidebar. The item ships hidden and is
// only revealed when installing is actually possible, so nobody clicks a
// button that cannot do anything.
//
// Two very different worlds:
//   * Chrome / Edge / Android — fire beforeinstallprompt. We stash the event
//     and replay it on click; that is the ONLY way to open the install dialog.
//   * iPhone / iPad — Safari never fires that event and has no install API at
//     all. The only route is Share -> Add to Home Screen, so there we just
//     show the instructions.
EC.installPrompt = null;

EC.isIos = function () {
    // iPadOS 13+ reports itself as a Mac, so the touch check is what catches iPads.
    return /iphone|ipod/i.test(navigator.userAgent) ||
           /ipad/i.test(navigator.userAgent) ||
           (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
};

EC.isInstalled = function () {
    return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
           navigator.standalone === true;
};

window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();              // stop the mini-infobar; we drive it from the menu
    EC.installPrompt = e;
    $('#ec-install-item').removeClass('d-none');
});

window.addEventListener('appinstalled', function () {
    EC.installPrompt = null;
    $('#ec-install-item').addClass('d-none');
    if (window.ecToast) ecToast('success', 'App installed.');
});

$(function () {
    var $item = $('#ec-install-item');
    if (!$item.length || EC.isInstalled()) return;

    // Safari gets no event, so reveal the item up front — it opens instructions.
    if (EC.isIos()) $item.removeClass('d-none');

    $('#ec-install-app').on('click', function () {
        if (EC.installPrompt) {
            EC.installPrompt.prompt();
            EC.installPrompt.userChoice.then(function (choice) {
                if (choice.outcome === 'accepted') $item.addClass('d-none');
                EC.installPrompt = null;
            });
            return;
        }

        if (EC.isIos()) {
            // danger:false — the default dialog is the red delete one.
            // The message is escaped into a single <p>, so keep it one paragraph.
            EC.confirm({
                title:   'Install SmartSchoolWala',
                danger:  false,
                icon:    'bx-download',
                message: 'In Safari, tap the Share button and choose "Add to Home Screen". ' +
                         'It only works in Safari — Chrome on iPhone/iPad cannot install apps.',
                okText:  'Got it'
            });
            return;
        }

        if (window.ecToast) {
            ecToast('info', 'Your browser cannot install this app. Try Chrome or Edge.');
        }
    });
});

// ── Image compression before upload ─────────────────────────────────────
// A phone camera shot is 5-12 MB, but the server caps uploads at 2 MB, so
// "Take photo" failed on virtually every device. Shrinking in the browser
// fixes that AND means the big file never crosses the school's mobile data.
//
// The defaults are sized off the biggest place a photo is ever shown: the ID
// card, at 22mm x 26mm. That is only ~260x307px at 300 DPI, so 800x1000 keeps
// 2.5x headroom and still lands around 150 KB.
//
//     EC.compressImage(file).then(function (smaller) { … });
//
// Returns a Promise<File>. Non-images, and anything that fails to decode, come
// back untouched — compression is an optimisation, never a gate on uploading.

// EXIF: phones store rotation as a flag rather than rotating the pixels.
// imageOrientation:'from-image' bakes it in; without it portrait photos upload
// lying on their side.
function ecLoadImage(file) {
    var viaBitmap = window.createImageBitmap
        ? Promise.resolve().then(function () {
              return createImageBitmap(file, { imageOrientation: 'from-image' });
          })
        : Promise.reject();

    return viaBitmap.catch(function () {
        return new Promise(function (resolve, reject) {
            var url = URL.createObjectURL(file);
            var img = new Image();
            img.onload  = function () { URL.revokeObjectURL(url); resolve(img); };
            img.onerror = function () { URL.revokeObjectURL(url); reject(new Error('decode failed')); };
            img.src = url;
        });
    });
}

function ecCanvasBlob(canvas, type, quality) {
    return new Promise(function (resolve) { canvas.toBlob(resolve, type, quality); });
}

EC.compressImage = function (file, opts) {
    opts = opts || {};
    var maxW    = opts.maxWidth  || 800;
    var maxH    = opts.maxHeight || 1000;
    var quality = opts.quality   || 0.82;
    var pngCap  = opts.pngMaxBytes || 1024 * 1024;

    if (!file || String(file.type).indexOf('image/') !== 0) return Promise.resolve(file);

    return ecLoadImage(file).then(function (img) {
        // Only ever shrink. Blowing a small photo up would add bytes, not save them.
        var scale = Math.min(1, maxW / img.width, maxH / img.height);
        var w = Math.max(1, Math.round(img.width  * scale));
        var h = Math.max(1, Math.round(img.height * scale));

        // PNG in -> PNG out, so a school logo keeps its transparency. Everything
        // else (camera JPEG, iPhone HEIC) becomes JPEG.
        var keepPng = file.type === 'image/png';

        function render(asPng) {
            var canvas = document.createElement('canvas');
            canvas.width = w; canvas.height = h;
            var ctx = canvas.getContext('2d');
            if (!asPng) {
                // Transparent pixels encode as BLACK in JPEG. Paint white first.
                ctx.fillStyle = '#ffffff';
                ctx.fillRect(0, 0, w, h);
            }
            ctx.drawImage(img, 0, 0, w, h);
            return ecCanvasBlob(canvas, asPng ? 'image/png' : 'image/jpeg', quality);
        }

        return render(keepPng).then(function (blob) {
            // A photo saved as PNG stays huge. If it is still heavy, drop the
            // transparency and take the JPEG instead.
            if (keepPng && blob && blob.size > pngCap) return render(false);
            return blob;
        }).then(function (blob) {
            if (img.close) img.close();
            if (!blob || blob.size >= file.size) return file;   // no win, keep original

            // Rename to match the new encoding — the server validates on extension,
            // so an iPhone "image.heic" must not arrive claiming to be HEIC.
            var base = String(file.name || 'image').replace(/\.[^.]+$/, '');
            var ext  = blob.type === 'image/png' ? '.png' : '.jpg';
            return new File([blob], base + ext, { type: blob.type, lastModified: Date.now() });
        });
    }).catch(function () {
        return file;   // could not decode — let the server have its say
    });
};

// Human-readable size, for the "2.4 MB → 180 KB" hints next to a picked image.
EC.fileSize = function (bytes) {
    if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
};

// Put a File back into a file input so a normal form POST sends the compressed
// version instead of the original the user picked.
EC.setInputFile = function (input, file) {
    try {
        var dt = new DataTransfer();
        dt.items.add(file);
        input.files = dt.files;
        return true;
    } catch (e) {
        return false;   // very old browser: the original file gets posted
    }
};

// ── Live form validation ────────────────────────────────────────────────
// Lifted out of the School Profile page, which had the pattern first, so every
// form can behave the same way instead of each growing its own checks.
//
// A rule takes the trimmed value and returns an error message, or '' when the
// value is fine. The SAME list drives the live feedback and the submit check,
// so the two can never drift apart:
//
//     EC.liveValidate('#addEnquiryModal form', {
//         StudentName:  EC.rule.required('Student name'),
//         FatherMobile: EC.rule.mobile,
//         ParentEmail:  EC.rule.email
//     });
//
// Fields not listed are left alone.

// Shared formats, so five pages don't grow five different mobile regexes —
// the same drift that once gave this project four copies of esc().
EC.rule = {
    required: function (label) {
        return function (v) { return v ? '' : label + ' is required.'; };
    },
    // Blank passes: use required() as well when the field is mandatory.
    mobile:  function (v) { return !v || /^[6-9][0-9]{9}$/.test(v)      ? '' : 'Enter a valid 10-digit mobile number.'; },
    email:   function (v) { return !v || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? '' : 'Enter a valid email address.'; },
    pincode: function (v) { return !v || /^[1-9][0-9]{5}$/.test(v)      ? '' : 'Enter a valid 6-digit pincode.'; }
};

EC.liveValidate = function (form, rules) {
    var $form = $(form);
    if (!$form.length) return null;

    // Turn off the browser's own bubbles. They fire BEFORE the submit event, so
    // without this a form with `required` fields shows a grey native popup for
    // some fields and our inline red text for others — two looks, one form.
    // The contract: every field you mark `required` in the markup needs a rule
    // here too, because nothing else checks it on the client any more.
    $form.attr('novalidate', 'novalidate');

    function check(name) {
        var $i = $form.find('[name="' + name + '"]');
        if (!$i.length || !rules[name]) return true;

        // A Bootstrap input-group (the "+91" prefix) is a flex row, so an error
        // dropped straight after the input lands INSIDE that row — beside the box
        // instead of under it, squashing the input. Hang it off the whole group.
        var $group = $i.closest('.input-group');
        var $after = $group.length ? $group : $i;

        var msg = rules[name]($.trim($i.val() || ''));
        $i.toggleClass('is-invalid', !!msg);
        $after.siblings('.live-error').remove();
        if (msg) $after.after('<span class="live-error text-danger small d-block">' + EC.esc(msg) + '</span>');
        return !msg;
    }

    function checkAll() {
        var bad = 0;
        for (var name in rules) { if (!check(name)) bad++; }
        if (!bad) return true;
        ecToast('warning', 'Please fix the highlighted fields.');
        $form.find('.is-invalid').first().trigger('focus');
        return false;
    }

    // blur/change checks the field you just left. input re-checks ONLY a field
    // already showing an error, so it clears the moment you fix it — checking on
    // every keystroke would shout "invalid email" at the first character typed.
    $form.on('blur change', 'input, select, textarea', function () { check($(this).attr('name')); });
    $form.on('input', 'input, textarea', function () {
        if ($(this).hasClass('is-invalid')) check($(this).attr('name'));
    });

    $form.on('submit', function (e) { if (!checkAll()) e.preventDefault(); });

    // Returned so an AJAX form (one that never really submits) can ask for the
    // same check before sending, and so a page can clear the marks on reset.
    return {
        isValid: checkAll,
        clear: function () {
            $form.find('.is-invalid').removeClass('is-invalid');
            $form.find('.live-error').remove();
        },
        check: check
    };
};

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
