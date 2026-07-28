# Frontend conventions

Everything the page JavaScript in this app is expected to share, and the traps
that come with it. Read this before touching any `.cshtml` script block.

The one rule behind all of it: **keep it simple**. Plain `var` + `function`,
no clever abstractions, no new dependencies. A dev with a couple of years'
experience should be able to read any of these helpers top to bottom and know
exactly what happens. If a change here needs a paragraph to explain, it is
probably the wrong change.

---

## `wwwroot/js/site.js` — the shared helpers

Loaded on every page from `Views/Shared/Sections/_Scripts.cshtml`, after jQuery.
Everything hangs off a single global `EC`.

| Helper | Use it for |
|---|---|
| `EC.showLoader()` / `EC.hideLoader()` | Thin progress bar at the top of the viewport, for a background fetch |
| `EC.buttonBusy($btn, 'Saving…')` / `EC.buttonReset($btn)` | Write actions — disables the button and shows a spinner |
| `EC.confirm(opts)` | Replaces `confirm()`. Returns `Promise<boolean>` |
| `EC.prompt(opts)` | Replaces `prompt()`. Returns `Promise<string\|null>`, supports `required: true` |
| `EC.listLoading(target, text)` | Spinner row inside a list while it loads |
| `EC.listEmpty(target, text, icon)` | "No data" / error row — see the rule below |
| `EC.listState(target, html)` | The shared row builder behind the two above |
| `EC.esc(s)` | HTML-escape anything from the database before putting it in an HTML string |
| `EC.money(n)` | `₹1,234.56` — Indian grouping, always two decimals |
| `EC.num(v)` | Safe `Number()`, keeps negatives (arithmetic results) |
| `EC.numPos(v)` | Safe `Number()`, clamps negatives to 0 (amounts the user typed) |

Notifications live separately, in `_Scripts.cshtml`:

```js
ecToast('success', 'Subjects saved.');
ecToast('error',   'Could not save.');
```

### Do not add a local copy of any of these

This is the whole point. Before the cleanup the project had **five** names for
"show a toast" (`toast`, `notify`, `toastSuccess`, `toastError`, `showToast`),
and two of them took their arguments in the **opposite order** — so copying a
line from one page to another silently showed the wrong thing. Same story with
four different `esc()` bodies, two `money()` bodies, and one `num()` name with
two different behaviours.

If a helper does not do what you need, change it in `site.js` for everybody.

---

## Loading and empty states

**Never block the whole page.** Show the loader where the data is changing, so
filters and pagination stay usable — the enquiry list relies on this, it aborts
the in-flight request when the user changes a filter.

```js
EC.showLoader();
EC.listLoading('#regBody');
$.get(url, filters)
    .done(function (d) {
        if (!d.success) {
            EC.listEmpty('#regBody', d.message || 'Could not load.', 'bx-error-circle');
            return;
        }
        if (!d.rows.length) { /* page's own empty panel */ return; }
        render(d.rows);
    })
    .fail(function () {
        EC.listEmpty('#regBody', 'Could not load. Please retry.', 'bx-error-circle');
    })
    .always(EC.hideLoader);
```

**Call `EC.listEmpty` on every path where no rows will arrive** — empty result,
error response, failed request. Three places in this app used to `return` early
and leave the spinner turning forever, which reads as "still loading".

A toast is not enough on its own: it disappears after 3.5s and the user is left
staring at a spinner.

---

## Buttons on write actions

Disabling the clicked button is the only blocking needed — it stops the
double-submit, which is the real risk.

```js
var $btn = $(this);
EC.buttonBusy($btn, 'Saving…');
$.post(url, data).always(function () { EC.buttonReset($btn); });
```

Skip the reset when the page navigates away (redirect or reload) — the button
should stay busy so a second click cannot fire.

---

## Confirm / prompt

```js
EC.confirm({
    title:   'Delete this class?',
    name:    'Class 5 — 3 sections',   // optional, shown highlighted
    message: 'This cannot be undone.',
    okText:  'Delete class'
}).then(function (ok) {
    if (!ok) return;
    deleteClass(id);
});
```

`danger` defaults to `true` (red button, trash icon). Pass `danger: false` for
anything that is not a delete.

For a form that just posts, no page script is needed at all:

```html
<form asp-action="Delete" method="post"
      data-ec-confirm="Delete this role?"
      data-ec-confirm-name="@r.RoleName"
      data-ec-confirm-message="Users must be reassigned first."
      data-ec-confirm-ok="Delete role">
```

`EC.prompt` adds a textarea. With `required: true` the confirm button stays
disabled until something non-blank is typed — the native `prompt()` only told
you about Cancel, so an empty reason used to reach the audit trail.

**Both are async.** A `confirm()` call is synchronous, so converting one always
means restructuring the rest of the handler into the `.then()` callback. There
is no mechanical way to do it; do them one at a time and check each.

---

## Traps in this codebase

These all cost real debugging time. They are still true.

**`asp-*` tag helpers need `_ViewImports.cshtml` in the area.** `Areas/ERP/Views/_ViewImports.cshtml`
was missing, so every `asp-action` / `asp-for` / `asp-append-version` in 48 ERP
views rendered as a literal HTML attribute and did nothing. Symptom: a link with
no `href`, or a form whose inputs have no `name` so nothing binds on POST. If a
new area is added, it needs its own `_ViewImports.cshtml`.

**A new `_ViewImports.cshtml` needs an app restart.** Razor runtime compilation
does not pick it up on its own. Touching the view files forces a recompile.

**`site.js` needs `asp-append-version`.** Without it the browser serves its
cached copy and every page throws `EC is not defined`.

**jQuery loads at the bottom of the page.** Anything rendered in the body —
a partial, an inline `<script>` — runs *before* jQuery exists. `_FeeReceiptModal`
used `$` there and threw `$ is not defined` on six pages, so its buttons never
got a handler. Use plain JS with event delegation in partials.

**`$` is shadowed in two files.** `FeeDueReminders/Index.cshtml` and
`PaymentVerification/Index.cshtml` do `const $ = s => document.querySelector(s)`.
Inside those files use `jQuery(...)` explicitly, never `$(...)`.

**`toastr.options` belongs in `_Scripts.cshtml` only.** Per-page overrides
replace the whole object, so a page silently loses settings it never mentioned.
`preventDuplicates` is deliberately `false`: toastr compares only against the
previous message, so with it on the same validation message never appears twice
in a row and the user thinks the button is dead.

**`EC.confirm` disposes the previous dialog before opening a new one.** Removing
a Bootstrap modal element without disposing it strands the backdrop and the page
becomes unclickable.

**The build does not check inline JavaScript.** `dotnet build` reports 0 errors
with a broken `<script>` block in a `.cshtml`. To check page JS, fetch the
rendered page and run each inline script through `new Function(src)` — it throws
on a syntax error without executing anything.

---

## What was migrated (do not reintroduce)

| Pattern | Before | Now |
|---|---|---|
| Toast function names | 5 (two with reversed arguments) | `ecToast` only |
| Toast wrappers / `toastr.options` blocks | 28 / 22 | 0 / 1 |
| `esc()` definitions | 14 across 4 variants | `EC.esc` |
| `money()` definitions | 8 across 2 variants | `EC.money` |
| `num()` definitions | 2 with different behaviour | `EC.num` + `EC.numPos` |
| Button spinner code | 22 copies | `EC.buttonBusy` / `EC.buttonReset` |
| `confirm()` / `prompt()` | 17 / 1 | `EC.confirm` / `EC.prompt` |
| `alert()` | 2 | 1 — the fallback inside `ecToast`, which must stay |

### Pages touched

`Admission/Create` · `AdmissionWorkflow/WorkflowSettings` · `Attendance/AttendanceReport` ·
`Attendance/StudentAttendance` · `Exam/CreateExam` · `Exam/MarkEntry` · `Fee/DayClose` ·
`Fee/ManageFee` · `Fee/Reports` · `FeeDueReminders/Index` · `IdCard/Index` ·
`Inventory/InventoryItem` · `Inventory/PurchaseEntry` · `Leave/LeaveManagement` ·
`PaymentVerification/Index` · `Payroll/PayrollManagement` · `Registration/Index` ·
`Roles/Index` · `SchoolSettings/{AcademicYears, AssignClassTeacher, BasicProfile, ClassSection,
Documents, EnquiryCRM, FeeHead, FeeStructure, PeriodStructure, SchoolCalendar, SmartBell,
StaffMasters, SubjectManagement, Timetable}` · `Staff/StaffProfile` ·
`Student/{EditStudent, Inactive, Promotion, StudentAttendance, StudentList}` · `Tc/Register` ·
`Transport/{Assign, Routes, Vehicles}` · `Views/Account/Error` · `Views/Dashboards/Index` ·
`Views/Shared/Sections/_Scripts` · `Views/Shared/_FeeReceiptModal`

---

## Known gaps

- **No linting on JavaScript.** Every bug found during this work was frontend,
  and a linter would have caught the shadowed `$`, the undefined `EC`, and a
  `function EC.esc(` that a bulk rename produced. This is the highest-value
  thing left to add.
- **~10,400 of 24,661 `.cshtml` lines are inline `<script>`.** Moving page JS
  into `wwwroot/js/pages/*.js` would make it lintable and editable with real
  tooling. `EnquiryCRM.cshtml` (1,871 lines) is the worst.
- **Not verified end to end:** the receipt format buttons and the TC void
  prompt — this school has no receipts and no TC records to exercise them.
- **`₹-100.00`** renders with the minus after the symbol. Cosmetic.
