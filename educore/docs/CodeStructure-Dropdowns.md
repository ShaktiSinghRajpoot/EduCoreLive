# Code Structure & Dropdown Conventions

This doc is the **single source of truth** for how dropdowns and cascading
(parent → child) selects are built in EduCore. It codifies the pattern ported
from the reference project (`UCS.CRM` / `CommonModule`) so every screen looks and
behaves the same.

> **Rule of thumb:** if a new screen needs a dropdown, copy the pattern below.
> Do **not** invent a new one, and do **not** reach for `JsonSerializer` for
> view binding.

---

## 1. The golden rules

1. **Static/pre-loaded dropdowns → `Model.XList` + `asp-items`.**
   The controller fills a `List<SelectListItem>` on the model; the view binds it
   with `asp-items`. No JSON, no client-side render loop.

2. **Cascading dropdowns (parent → child) → jQuery `$.post` + build `<option>`s.**
   On parent `change`, POST the parent value to a `[HttpPost]` action that returns
   `Json(...)`, then append `<option>` elements to the child. This is the
   CRM-style AJAX cascade.

3. **NO `JsonSerializer` / `@Html.Raw(Json...)` for binding data into a view.**
   Prefilling an edit form, seeding a list, populating a dropdown — all use
   **normal Razor binding** (`value="@..."`, `selected="@(...)"`) or
   `data-*` attributes. JSON blobs in views are banned.

4. **`JsonSerializer` in the C# service layer is fine** — but only for building
   **Postgres `jsonb` proc parameters**, never for view data.

5. **Real batch-save "builders" may keep a JSON payload** (e.g. Class-Section
   grid that saves many rows in one POST). That is a data-submission payload,
   not view binding — it's the one allowed exception.

---

## 2. Static / pre-loaded dropdown

### Model
```csharp
public class StaffModel
{
    public int? DepartmentId { get; set; }
    public List<SelectListItem> DepartmentList { get; set; } = new();
    public List<RoleOption> RoleList { get; set; } = new();
}
```

### Controller — fill the list before returning the view
```csharp
private async Task FillDropdownsAsync(StaffModel model)
{
    var dd = await _staffService.GetDropdownsAsync(TenantId, SchoolId, UserId);

    model.DepartmentList = dd.Departments
        .Select(d => new SelectListItem { Text = d, Value = d })
        .ToList();

    model.RoleList = dd.Roles; // already List<RoleOption>
}
```

### View — bind with `asp-items`
```cshtml
<select asp-for="DepartmentId" id="Department" class="form-select"
        asp-items="@(new SelectList(Model.DepartmentList, "Value", "Text"))">
    <option value="">-- Select Department --</option>
</select>
```

> **Never** loop in the view to `@Html.Raw(JsonSerializer.Serialize(list))` and
> render options in JS. Use `asp-items`.

---

## 3. Cascading dropdown (parent → child) — the CRM AJAX pattern

Example: **Department → Designation**. Pick a department, only that department's
designations load.

### Controller — `[HttpPost]` action returns `Json`
```csharp
[HttpPost]
public async Task<IActionResult> GetDesignations(string department)
{
    var list = await _staffService.GetDesignationsAsync(
        TenantId, SchoolId, UserId, department);

    // shape: value / text (+ any extra fields the child needs)
    return Json(list.Select(d => new {
        value = d.Name,
        text  = d.Name,
        type  = d.StaffType        // extra payload carried on the option
    }));
}
```

### View — POST on change, build `<option>`s
```javascript
function BindDesignations(department, keep) {
    var $desig = $("#Designation");
    $desig.empty().append('<option value="">-- Select Designation --</option>');
    if (!department) return;

    $.post('@Url.Action("GetDesignations", "Staff", new { area = "ERP" })',
        { department: department },
        function (data) {
            $.each(data, function (i, item) {
                $("<option></option>")
                    .val(item.value)
                    .html(item.text)
                    .attr('data-type', item.type)   // extra payload → data-attr
                    .appendTo($desig);
            });
            if (keep) $desig.val(keep);             // re-select on edit prefill
        });
}

// wire it up
$("#Department").on('change', function () {
    BindDesignations($(this).val(), null);
});

// on edit page load, restore both levels:
$(function () {
    var dept = $("#Department").val();
    if (dept) BindDesignations(dept, '@Model.DesignationName');
});
```

### Key points
- **Server-side filter** — the child list is fetched per-parent from the DB, not
  filtered client-side from a pre-serialized blob.
- Extra data the child needs (e.g. Staff Type derived from Designation) rides on
  a **`data-*` attribute**, read later with `$opt.data('type')`.
- On **edit**, pass the saved child value as `keep` so it re-selects after the
  async load.

---

## 4. Edit-form prefill — normal binding, NOT JSON

**Wrong** (banned):
```cshtml
<script>
  var DATA = @Html.Raw(JsonSerializer.Serialize(Model.Years));
  // ...render rows / prefill fields from DATA in JS
</script>
```

**Right** — server-render with Razor + `data-*`:
```cshtml
@foreach (var y in ViewBag.Years as List<AcademicYear>)
{
    <tr>
        <td>@y.Name</td>
        <td>
            <button class="btn-edit"
                    data-id="@y.Id"
                    data-name="@y.Name"
                    data-start="@y.StartDate:yyyy-MM-dd"
                    data-end="@y.EndDate:yyyy-MM-dd">Edit</button>
        </td>
    </tr>
}
```
```javascript
$('.btn-edit').on('click', function () {
    var b = this.dataset;
    $('#Id').val(b.id);
    $('#Name').val(b.name);
    $('#StartDate').val(b.start);
    $('#EndDate').val(b.end);
});
```

Boolean selects use Razor directly:
```cshtml
<option value="1" selected="@(Model.IsActive)">Active</option>
```

---

## 5. Where JSON *is* allowed

| Location | Allowed? | Why |
|---|---|---|
| View: dropdown / list / prefill data | ❌ | Use `asp-items`, `@foreach`, `data-*`, Razor binding |
| Service (`.cs`): building a Postgres `jsonb` proc param | ✅ | Legitimate DB payload, not view data |
| A true multi-row **batch-save builder** payload (e.g. Class-Section grid) | ✅ | It's a submission payload, one POST saves many rows |

---

## 6. Screens already on this pattern (reference implementations)

- **Staff** — `Areas/ERP/Views/Staff/AddStaff.cshtml`, `EditStaff.cshtml`
  (Department → Designation cascade; Staff Type derived silently from
  Designation via `data-type`).
- **Staff Masters** — `Areas/Admin/Views/SchoolSettings/StaffMasters.cshtml`.
- **Academic Years** — `Areas/Admin/Views/SchoolSettings/AcademicYears.cshtml`
  (converted from JSON blob → server-rendered `@foreach` + `data-*`).
- **Fee Structure** — `Areas/Admin/Views/SchoolSettings/FeeStructure.cshtml`
  (dup-check reads `.structure-row` data-attrs, no serialized blob).
- **Admission** — `Areas/ERP/Views/Admission/Create.cshtml` (prefill via normal
  binding; cascade fires only when both class & year are set).

When building a new screen, copy the closest one above.

---

## 7. Checklist before you commit a new dropdown screen

- [ ] Static lists use `Model.XList` + `asp-items` (no view-side JSON).
- [ ] Cascades use `$.post` → `[HttpPost]` action → `Json`, build `<option>`s.
- [ ] Extra child data rides on `data-*` attributes.
- [ ] Edit prefill uses Razor `value=`/`selected=` + `data-*`, not a JSON blob.
- [ ] Every service call threads `tenantId, schoolId, actionUserId`.
- [ ] `JsonSerializer` appears only in services (for `jsonb` params) — never in a view.
