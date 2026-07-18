# Server-Side Pagination + Sorting — Rollout Checklist

Pattern reference: **Fee Head** (`SchoolSettings/FeeHead`) — this is the pilot. Har naye page pe wahi 7 steps repeat honge.

## "One model does everything" — kya hota hai

Ek hi model (jo `ListModelBase` inherit karta hai) view mein **4 kaam** karta hai:
listing (`Items`) + field binding (form fields) + dropdowns (`XList`) + filter/pagination/sort (base ke props).

---

## Shared plumbing — EK BAAR banaya, DONE ✅

Ye teen cheezein sabhi pages share karte hain, dobara nahi banani:

- [x] `EduCoreDataAccessLayer/Models/ListModelBase.cs` — base class (Page, PageSize, SortColumn, SortDir, Search, TotalCount, Offset, HasPrev/Next, FirstRow/LastRow…)
- [x] `educore/Views/Shared/_Pager.cshtml` — reusable pager partial (query string preserve karta hai, sirf `Page` swap)
- [x] `educore/Views/Shared/_PageSize.cshtml` — reusable "Rows per page" selector; pass filter form id via `ViewData["FormId"]`
- [x] `educore/wwwroot/css/site.css` — `.ec-pager` / `.ec-pager-btn` styles

---

## Per-page checklist (Fee Head = template) — har master pe ye 7 steps

1. **Model** — `class X : ListModelBase`; add `List<X> Items { get; set; } = new();` + filter props (jaise `FilterFrequency`). Filter props ko form-field props se alag naam do.
2. **SQL proc** — `core.sp_<x>_list(p_tenant_id, p_school_id, p_action_user_id, p_search, <p_filters…>, p_page_no, p_page_size, p_sort_column, p_sort_dir, INOUT p_result refcursor)`. Scope guard + `COUNT(*) OVER() AS total_count` + **whitelisted CASE-based ORDER BY** (SQL-injection safe) + `LIMIT/OFFSET`.
3. **Contract** — `Task<X> GetXPageAsync(X query, int tenantId, int schoolId, int actionUserId);`
4. **Repository** — implement (uncached), params bind, rows → `query.Items`, `query.TotalCount` = total_count column, return query. **Existing cached getter mat chhedo.**
5. **Controller** — action signature `Task<IActionResult> X(X query)`; tenant/school/user id **claims se** (model se NAHI); `GetXPageAsync` call; `return View(query)`.
6. **View** — `@model X`; list source `Model.Items`; filter bar ko `<form method="get" id="...">` banao (Search + filter/sort selects, `onchange this.form.submit()`); footer mein `Model.FirstRow/LastRow/TotalCount` + `<partial name="_Pager" model="Model" />` + `<partial name="_PageSize" model="Model" view-data='@(new ViewDataDictionary(ViewData){{ "FormId", "yourFormId" }})' />`; **client-side filter/sort JS hatao**. (`@using Microsoft.AspNetCore.Mvc.ViewFeatures` chahiye ViewDataDictionary ke liye.)
   - ⚠️ **GOTCHA:** view ke top pe `@addTagHelper *, Microsoft.AspNetCore.Mvc.TagHelpers` ZAROORI hai. Area views root `/Views/_ViewImports.cshtml` inherit **nahi** karte, aur ERP area ka apna `_ViewImports` nahi hai — is line ke bina `<partial>` (pager) aur saare `asp-*` tag helpers **chup-chaap dead** ho jaate hain (page load hota hai, bas pager/URLs render nahi hote).
7. **DB + verify** — proc DB pe apply karo; page load karke pagination + sort + filter check karo.

---

## Pages to roll out — priority order

Legend: 🟢 done · ⬜ pending · ➖ not a list (skip)

**Har candidate page ko actually inspect karke classify kiya** (guess nahi). Har page ke aage decision + wajah.

### ✅ DONE — pattern rollout ho gaya (server-side, shared partials, verified)
- [x] 🟢 `SchoolSettings/FeeHead` — pilot; `core.sp_fee_head_list`
- [x] 🟢 `Student/StudentList` — `core.sp_student_list`; search/filter/sort/paging + summary tiles + export
- [x] 🟢 `Staff/StaffList` — `core.sp_staff_list`; search/dept/type/status filter + sort + paging; verified 12-staff / 2-page
- [x] 🟢 `Staff/Inactive` — `core.sp_staff_list` reuse (status pinned=Inactive) + search + sort + pager; verified

### 🟡 ALREADY server-side paginated — pattern ki zaroorat nahi (functional goal already met)
- `SchoolSettings/EnquiryCRM` — full **AJAX CRM** (pipeline tabs + KPI); `GetEnquiriesData` → `GetEnquiriesAsync` backend **already paginates** (page/pageSize/TotalCount). Yahan client-side pager AJAX interaction ke liye sahi hai; full-page `_Pager` mein convert karna bada rewrite + UX regression (smooth tab-filtering chali jayegi). **Skip.**
- `Registration/Index` — `RegistrationPageModel`, AJAX-driven (Enquiry jaisa pipeline). Backend already server-side. **Skip.**
- `SuperAdmin/Schools/SchoolList` — controller `GetSchoolsAsync(... page,pageSize)` **already server-side** paginate + filter karta hai (saara paging info ViewBag mein, apna pager). Functional goal met. **Optional** consistency-refactor to shared `_Pager`/`_PageSize` **defer kiya**: (a) SuperAdmin area (tenant 1) — school-admin login se verify nahi hota, (b) iske query params lowercase `page`/`pageSize` hain vs shared partials `Page`/`PageSize` → dono ek saath URL mein aane ka risk; safe swap ke liye poori view align karni padegi. Untestable + risky, isliye chhoda.

### ⚪ STUB — abhi backend/data path hi nahi (`return View()`, koi service call nahi)
Inko pehle apna feature (proc + service + real data) chahiye; tab tak "pagination lagao" ka koi matlab nahi. Jab feature banega tabhi is pattern ke saath banana:
- `Student/Inactive` (client-side demo data), `Inventory/InventoryItem`, `Inventory/PurchaseEntry`,
  `FeeDueReminders/Index`, `PaymentVerification/Index`, `Fee/Reports` (AJAX report screen),
  `Leave/LeaveManagement`, `Payroll/PayrollManagement`

### 🔵 AJAX CRUD masters (chhoti data, apna live-fetch) — pattern fit nahi / low value
- `Transport/Routes`, `Transport/Vehicles`, `Transport/Assign` — AJAX add/edit, data usually kam. **Skip.**

### 🔸 Chhote config masters (rows hamesha kam; pagination overkill)
Zaroorat pade to **sirf sorting** add ho sakti hai, pagination nahi:
- `SchoolSettings/ClassSection`, `SchoolSettings/SubjectManagement`, `SchoolSettings/StaffMasters`,
  `SchoolSettings/AcademicYears`, `Roles/Index`

### ➖ Not a list — forms/dashboards/entry screens
`Admission/Create`, `Admission/Dashboard`, `Student/Dashboard`, `Student/EditStudent`, `Student/Promotion`,
`Staff/AddStaff`, `Staff/EditStaff`, `Staff/StaffProfile`, `Exam/*`, `Attendance/*`,
`SchoolSettings/{BasicProfile,FeeStructure,Timetable,PeriodStructure,AssignClassTeacher}`,
`AdmissionWorkflow/WorkflowSettings`, `Roles/Permissions`, `Fee/ManageFee`, `Fee/DayClose`.

---

## Bottom line
Jitne pages **genuinely** is pattern ke fit the (poora dataset load karke client-side filter/paginate kar rahe the) — **sab ho gaye**: FeeHead, StudentList, StaffList, Staff/Inactive. Baaki ya to **already server-side** hain (Enquiry/Registration/SchoolList), ya **stub** (backend hi nahi), ya **chhoti config/forms**. Naya list-page bane to step 1–7 follow karke ban jayega.
