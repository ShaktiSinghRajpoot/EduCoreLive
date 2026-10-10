# Inventory / Store: test catalog

**Scope:** `Areas/ERP/Controllers/InventoryController.cs`, `Views/Inventory/{InventoryItem,PurchaseEntry}.cshtml`,
`EduCoreDataAccessLayer/Services/Repository/ERP/InventoryService.cs`, and procs
`core.sp_inventory_manage` / `core.sp_inventory_purchase_manage` (`Database/inventory.sql`, plus the
helpers `core.fn_inventory_default_location` / `fn_inventory_post_movement` / `fn_inventory_user_name`
since the locations revision). No later script redefines them. The live definitions were read with `pg_get_functiondef` and match the script.

**SQL suite:** `EduCoreDataAccessLayer/Database/tests/inventory_store_tests.sql`. It goes deeper than
`tests/inventory_tests.sql` (49 checks, all PASS) and repeats none of its checks. It runs in one
transaction and rolls back. Fixture: tenant 24 / school 34 / user 39. The other school is 23 / 33.

```
export PGPASSWORD=root; "/c/Program Files/PostgreSQL/16/bin/psql.exe" -U postgres -d educore -q \
  -f EduCoreDataAccessLayer/Database/tests/inventory_store_tests.sql 2>&1 | sed 's/^psql:[^ ]* NOTICE:  //'
```

**First run (2026-10-10):** `RESULT: 106 passed, 10 failed`, all 10 app bugs.
**After the fixes (2026-10-10):** `RESULT: 142 passed, 0 failed`; `inventory_tests.sql` 49/49.
**Store locations / transfers / returns / supplier screen (2026-10-10b):** new suite
`tests/inventory_locations_tests.sql`, `RESULT: 111 passed, 0 failed`, first run. See section L below.
Both older suites still 142/0 and 49/0, and all 31 suites in `Database/tests` are green. The suite now
asserts the corrected behaviour (no `BUG` names left). After the rollback, 0 `ZZS%` rows are left.
Fixes are in `Database/inventory.sql` (re-runnable, applied with `psql -v ON_ERROR_STOP=1 -f`),
`InventoryService.cs`, `InventoryModels.cs`, `InventoryController.cs` and both Inventory views.

Rule under test: **stock on hand = sum of its movements**, and every movement keeps who, when, qty,
why and its reference. Nothing is overwritten or hard-deleted.

---

## Stock trail map

| Event | Item `current_stock` | `inventory_stock_ledger` row | Other durable record | Who / when kept |
|---|---|---|---|---|
| Create item with opening N | set to N | `Opening`, +N, balance N (only if N ≠ 0) | item row (`created_by/at`) | ledger `created_by`, `movement_date`, `created_at` |
| Edit item | **never changes** (ITM-06) | none | item row overwritten in place (name, unit, cost): **no history** | `updated_by/at` only (last edit) |
| Delete item | must be 0 first | none | `is_deleted = TRUE` (soft); ledger + bill lines survive | `updated_by/at` |
| Issue / Damage | − qty | `Issue`/`Damage`, −qty, balance, `issued_to`, `remarks` | none | ledger |
| Return / Adjustment | + qty | `Return`/`Adjustment`, +qty | none | ledger |
| Purchase (n lines) | + qty per line | one `Purchase` row per line, `reference_type='Purchase'`, `reference_id=purchase_id`, `movement_date = bill date` | header (totals, supplier name **snapshot**, invoice) + lines (item name **snapshot**, qty, rate, tax%) | header `created_by/at` |
| Cancel purchase | − each line qty | one `PurchaseCancel` row per line, same reference, reason in `remarks` | header `is_cancelled`, `cancel_reason`, `cancelled_by/at`; lines kept | header + ledger |
| Delete supplier | n/a | n/a | `is_deleted = TRUE`; old bills keep `supplier_id` + name snapshot | `updated_by/at` |
| Recount | rebuilt from SUM(ledger) for live items of the school | none | none | `updated_by/at` |

Since the fixes, every movement keeps its **rate** (`unit_rate`: the bill's rate for a purchase or its
cancel, the item's cost price otherwise; NULL on rows written before) and the history shows **who**.
A `StockTake` row records a physical count (the difference, signed). Still true: item edits (cost price)
keep no history, and nothing at the DB level stops a direct UPDATE or DELETE on the ledger. No inventory
proc does that (LED-07), but there is no trigger guard.

---

## A. Item master (ITM)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ITM-00 | Fixture items | Tie (opening 50, min 10, cost 40), Notebook (0, min 20) | created | proc | SQL ITM-00 | PASS |
| ITM-01 | Negative opening stock | SaveItem opening = −5 | refused | proc | SQL ITM-01 | FIXED: refused "Opening stock cannot be negative." (proc) + `chk_inv_item_stock` on the table |
| ITM-02 | Negative cost price | cost = −40 | refused | proc | SQL ITM-02 | FIXED: negative cost/selling price refused (proc) + `chk_inv_item_price`; ITM-02b..d add selling price and 3-decimal checks |
| ITM-03 | Negative reorder level | min = −1 | refused | proc | SQL ITM-03 | PASS |
| ITM-04 | Duplicate name, other case/spaces | "  zzs TIE  " | refused | DB index | SQL ITM-04 | PASS (user sees the raw constraint name, see UI-07) |
| ITM-05 | Duplicate SKU, other case/spaces | " zzs-tie " | refused | DB index | SQL ITM-05 | PASS |
| ITM-06 | Edit cannot move stock | edit with opening 999 | stock and ledger unchanged | proc | SQL ITM-06/06b | PASS |
| ITM-07 | Rename onto another item's name | Notebook → "ZZS Tie" | refused | DB index | SQL ITM-07 | PASS |
| ITM-08 | Cross-school edit by id | school 33 edits our item | "Item not found", unchanged | proc | SQL ITM-08/08b | PASS |
| ITM-09 | Cross-school GetItem | school 33 reads our id | 0 rows | proc | SQL ITM-09 | PASS |
| ITM-10 | XSS in item name | `<img src=x onerror=alert(1)>` | stored verbatim, escaped on render | proc + view | SQL ITM-10; static `InventoryItem.cshtml:492-518` (`EC.esc`), `PurchaseEntry.cshtml:301` | PASS |
| ITM-11 | Numeric-looking name / SKU | "00123" / "1e5" | stays text | proc + view | SQL ITM-11; static: names never go through `.data()`, only integer ids do (`InventoryItem.cshtml:503-506,714-718`) | PASS |
| ITM-12 | Unknown item type | "Weird" | refused | DB check | SQL ITM-12 | PASS |
| ITM-13 | Name > 150 chars | 151 × Z | refused | DB | SQL ITM-13 | PASS |
| ITM-14 | Opening beyond numeric(14,2) | 1e13 | refused, no half item | DB | SQL ITM-14/14b | PASS |
| ITM-15 | Opening movement has author/date | | `created_by` = 39, today | proc | SQL ITM-15 | PASS |
| ITM-16 | Unit changed after stock exists | 3 Box → Piece | accepted silently | proc | SQL ITM-16 (doc) | FIXED (rule D-8): refused once the item has ledger rows; an item with no history may still change (ITM-16b/c) |
| ITM-17 | Cross-school delete | school 33 deletes Notebook | refused, still live | proc | SQL ITM-17/17b | PASS |
| ITM-18 | Edit when category is not in the dropdown | `#itemCategory.val(d.category)` | category kept | view | static `InventoryItem.cshtml:558,590` | FIXED: an unlisted category is added to the dropdown before it is selected |

## B. List, low stock, valuation (LST)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| LST-01 | Status: above min → Available, 0 → Out of Stock, exactly at min → Low Stock | as stated | proc | SQL LST-01 | PASS |
| LST-02 | Stock value = stock × cost | 5 × 12.50 = 62.50 | proc | SQL LST-02 | PASS |
| LST-03 | Low-stock filter | only Low Stock rows, includes the item at its level | proc | SQL LST-03 | PASS |
| LST-04 | Search by SKU, any case, trimmed | 1 row | proc | SQL LST-04 | PASS |
| LST-05 | No foreign or deleted items in the list | 0 | proc | SQL LST-05 | PASS |
| LST-06 | Search / paging / sort | client-side over the full list | view | static `InventoryItem.cshtml:427-535` | PASS (the server `p_search` is unused by the page) |
| LST-07 | Summary cards match the table | computed from the same rows | view | static `InventoryItem.cshtml:453-464` | PASS |

## C. Stock movement (MOV)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| MOV-01 | 3-decimal issue | stock 10, Issue 0.335 | stock = SUM(ledger), balance is a running sum | proc | SQL MOV-01/01b | FIXED (rule D-11): more than 2 decimals refused in the proc and the page; a 2-decimal issue keeps stock = SUM(ledger) (MOV-01b/c) |
| MOV-02 | Negative qty | −5 | refused | proc | SQL MOV-02 | PASS |
| MOV-03 | Qty that rounds to 0.00 | 0.004 | refused, stock untouched | DB check | SQL MOV-03/03b | PASS |
| MOV-04 | Wrong-case movement type | "issue" | refused | proc | SQL MOV-04 | PASS |
| MOV-05 | Issue to a class | 12 to "  Class 6B  " | 50 → 38 | proc | SQL MOV-05 | PASS |
| MOV-06 | Row content | | type, −12, issued_to trimmed, remarks, author, today | proc | SQL MOV-06 | PASS |
| MOV-07 | Damaged goods | Damage 3 | 38 → 35 | proc | SQL MOV-07 | PASS |
| MOV-08 | Stock-take finds less | Adjustment | can only ADD | proc | SQL MOV-08 (doc) | FIXED (rule D-2): new `StockTake` movement: enter the counted quantity, the difference (up or down) is recorded, a reason is required (MOV-08b..i). Adjustment stays "add found stock" |
| MOV-09 | Issue the exact balance | 4 of 4 | lands on 0 | proc | SQL MOV-09 | PASS |
| MOV-10 | Damage on an empty shelf | 0.01 of 0 | refused "Only 0.00 … left" | proc | SQL MOV-10 | PASS |
| MOV-11 | Deleted item | Return on deleted, delete twice, GetItem, ItemLedger | refused / refused / 0 rows / history still readable | proc | SQL MOV-11..11d | PASS |
| MOV-12 | Huge qty | Return 1e13 | refused, no ledger row | DB | SQL MOV-12/12b | PASS |
| MOV-13 | Inactive item | Issue 1 | accepted | proc | SQL MOV-13 (doc) | FIXED (rule D-6): Issue of an Inactive item refused; its old stock can still be returned, written off or counted (MOV-13b) |
| MOV-14 | Transfer between stores/departments | n/a | not supported (only Issue with free-text "issued to") | proc | static `inventory.sql` MOVESTOCK type list | BUILT (D-10): store locations + `Transfer`, see section L (TRF-*) |

## D. Suppliers (SUP)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| SUP-01 | Blank name | refused | proc | SQL SUP-01 | PASS |
| SUP-02 | Duplicate name, other case/spaces | refused | DB index | SQL SUP-02 | PASS |
| SUP-03 | Cross-school edit | refused | proc | SQL SUP-03 | PASS |
| SUP-04 | Cross-school delete | refused, unchanged | proc | SQL SUP-04/04b | PASS |
| SUP-05 | Purchase naming another school's supplier | refused | proc | SQL SUP-05 | PASS |
| SUP-06 | Other school's list excludes ours | 0 | proc | SQL SUP-06 | PASS |
| SUP-07 | Delete a supplier that has bills | soft delete | proc | SQL SUP-07 | PASS |
| SUP-08 | Old bill still names the deleted supplier | name snapshot kept | proc | SQL SUP-08 | PASS |
| SUP-09 | Deleted supplier on a new bill | refused | proc | SQL SUP-09 | PASS |
| SUP-10 | Re-add the same supplier name, re-enter an old bill number | accepted: same bill counted twice (index keyed on `supplier_id`) | DB index `inventory.sql:156` | SQL SUP-10 (doc) | KEPT (rule D-9): documented, no change |
| SUP-11 | XSS in supplier name | escaped | view | static `PurchaseEntry.cshtml:82` (Razor `@`), `:454,527` (`EC.esc`) | PASS |
| SUP-12 | Supplier list / edit / delete screen | exists | view | `Views/Inventory/SupplierMaster.cshtml` | BUILT: list, search, status filter, add/edit, activate/deactivate, remove (soft), bills per supplier (section L, SUL-*) |

## E. Purchases (PUR)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| PUR-01 | Multi-line GST bill | 100 @ 40 + 5%, 200 @ 20 + 12% | 8680 header = sum of lines; stock +100 | proc | SQL PUR-01/01b/01c | PASS |
| PUR-02 | One movement per line, with author/date/ref | | 2 rows | proc | SQL PUR-02 | PASS |
| PUR-03 | Same bill no., different supplier | | allowed | DB index | SQL PUR-03 | PASS |
| PUR-04 | Same bill no., same supplier, other case/spaces | "  zzs-b-1 " | refused | DB index | SQL PUR-04 | PASS |
| PUR-05 | Same bill twice with no supplier picked | | refused | DB index | SQL PUR-05 | FIXED: proc refuses "Bill X from no supplier is already entered"; index now keys on `COALESCE(supplier_id, 0)` (PUR-05b) |
| PUR-06 | Negative tax % | −18 on line 2 | refused whole | DB check | SQL PUR-06 | PASS (raw constraint text) |
| PUR-07 | Tax % > 100 | 128 | refused | DB check | SQL PUR-07 | PASS |
| PUR-08 | Negative rate | −40 | refused | proc | SQL PUR-08 | PASS |
| PUR-09 | Line without item | itemId null | refused | proc | SQL PUR-09 | PASS |
| PUR-10 | Line without qty | | refused | proc | SQL PUR-10 | PASS |
| PUR-11 | Lines not an array | object | refused | proc | SQL PUR-11 | PASS |
| PUR-12 | Unknown supplier id | 999999 | refused | proc | SQL PUR-12 | PASS |
| PUR-13 | No date | NULL | refused | proc | SQL PUR-13 | PASS |
| PUR-14 | Huge bill | 1e9 × 1e6 | refused; no row, no stock change (PUR-06..14) | DB | SQL PUR-14/14b | PASS |
| PUR-15 | Free sample | rate 0 | accepted, total 0, stock up | proc | SQL PUR-15 | PASS |
| PUR-16 | Paise rounding | 2.5 × 33.33 + 18% | header = sum of line totals | proc | SQL PUR-16/16b | FIXED: each line rounds base and tax once, header = sum of lines (98.33 both); page uses the same arithmetic |
| PUR-17 | 3-decimal purchase qty | 1.005 + 2.335 | stock = SUM(ledger); header = stored qty × rate | proc | SQL PUR-17/17b | FIXED (rule D-11): 3-decimal qty or rate refused, no bill written (PUR-17..17c); Inactive item refused (PUR-17d) |
| PUR-18 | Same item on two lines | 30 + 20 | +50, balances running | proc | SQL PUR-18/18b | PASS (the cancel breaks it, see CAN-10) |
| PUR-19 | Back-dated bill | 2001-01-01 | accepted; ledger row dated 2001 but newest id | proc | SQL PUR-19 (doc) | KEPT (rule D-4): back-dated allowed, future refused; history now shows date order (LED-01) |
| PUR-20 | Date filter | from = to = 2001-01-01 | only that bill | proc | SQL PUR-20 | PASS |
| PUR-21 | Rename item after a bill | | bill line keeps the old name | proc | SQL PUR-21 | PASS |
| PUR-22 | Cross-school Get | | 0 rows in both cursors | proc | SQL PUR-22 | PASS |
| PUR-23 | Cross-school List | | none of ours | proc | SQL PUR-23 | PASS |
| PUR-24 | Future date | | refused | proc | existing `inventory_tests.sql` E2 | PASS |
| PUR-25 | Purchase detail view | view lines of a saved bill | exists | view | `PurchaseEntry.cshtml` history → View | BUILT: lines with returned qty/amount, returns (who/when/reason), cancel status, entered/cancelled by and at, return-to-supplier form (section L) |
| PUR-26 | Default date on the form | today (school clock) | local date | view | static `PurchaseEntry.cshtml:428,541` `toISOString()` | FIXED: default and `max` come from the server's school date (`Dates.Today`) |

## F. Cancelling a purchase (CAN)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| CAN-01 | Cross-school cancel | school 33 cancels our bill | refused, still live | proc | SQL CAN-01/01b | PASS |
| CAN-02 | Cancel after part of the goods were issued | Tie 10 + Chalk 10; issue 8 chalk | refused with arithmetic | proc | SQL CAN-02 | PASS |
| CAN-03 | ...no half-reversal | | tie rows/stock unchanged; chalk 7; bill live | proc | SQL CAN-03/03b | PASS |
| CAN-04 | Clean cancel keeps everything | | totals, `cancelled_by/at`, trimmed reason | proc | SQL CAN-04 | PASS |
| CAN-05 | Lines kept | | 2 lines | proc | SQL CAN-05 | PASS |
| CAN-06 | Reversal rows | | 2 Purchase + 2 PurchaseCancel, with author + reason | proc | SQL CAN-06/06b | PASS |
| CAN-07 | Running balance after cancel | | drift 0, balances running | proc | SQL CAN-07/07b | PASS |
| CAN-08 | Re-enter the corrected bill under the same number | | allowed | DB index | SQL CAN-08 | PASS |
| CAN-09 | Cancel with a blank reason | "   " | accepted, reason NULL | proc | SQL CAN-09 (doc) | FIXED (rule D-5): proc refuses a blank reason; bill stays live (CAN-09b) |
| CAN-10 | **Cancel a bill with the same item on two lines** | Notebook 30 + 20, cancel | stock = SUM(ledger) | proc | SQL CAN-10/10b | FIXED: cancel locks the items, checks per item, then reverses line by line with `UPDATE ... RETURNING` (fresh stock each line) |
| CAN-11 | ...and the below-zero guard is bypassed | 30 + 20 bought, 15 issued (35 left), cancel | refused | proc | SQL CAN-11 | FIXED: refused with the bill's TOTAL for the item ("only 35.00 ... brought in 50.00"); stock still matches its ledger (CAN-11b) |
| CAN-12 | Cancel button wording | "Cancel purchase" | view | static `PurchaseEntry.cshtml:474-480` | FIXED: `EC.prompt` with name (bill, supplier, total), message, okText "Cancel purchase", icon bx-x-circle |

## G. The ledger is the stock (LED)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| LED-01 | Item history is newest first | first row = max id | proc | SQL LED-01 | PASS |
| LED-02 | Cross-school history | 0 rows | proc | SQL LED-02 | PASS |
| LED-03 | Every fixture item: stock = SUM(ledger) | 0 drifted | proc | SQL LED-03 (excludes the 3 items already failed by MOV-01/CAN-10/11) | PASS |
| LED-04 | Every fixture item: balance_after is a running sum | 0 | proc | SQL LED-04 | PASS |
| LED-05 | No item below zero | 0 | proc | SQL LED-05 | PASS |
| LED-06 | Every bill: sub total = sum(stored qty × rate) | 0 | proc | SQL LED-06 (excludes the PUR-17 bill) | PASS |
| LED-07 | No proc hard-deletes inventory rows or edits the ledger / bill lines | 0 matches in `pg_proc.prosrc` | DB | SQL LED-07 | PASS |
| LED-08 | Another school's Recount leaves ours alone; ours repairs it | 777 stays; then 0 | proc | SQL LED-08/08b | PASS |
| LED-09 | History screen shows who | author column | proc + view | static `inventory.sql:473` (ITEMLEDGER selects no `created_by`), `InventoryItem.cshtml:670-681` | FIXED: history returns and shows who (profile name), the rate (`unit_rate`) and the bill number (LED-01d) |

## H. Scope and permissions (TEN / PERM)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| TEN-01 | Platform scope, purchase List | refused | proc | SQL TEN-01 | PASS |
| TEN-02 | Platform scope, Recount | refused | proc | SQL TEN-02 | PASS |
| TEN-03 | school_id 0 | refused | proc | SQL TEN-03 | PASS |
| TEN-04 | No leak; every ledger/bill-line row matches its parent's school | 0 | DB | SQL TEN-04 | PASS |
| PERM-01 | View vs manage | reads need `inventory.view`, writes need `inventory.manage` | controller | static `InventoryController.cs:12` | FIXED (rule D-1): class `[HasPermission("inventory.view")]`, all 7 write actions `inventory.manage`. **Follow-up outside my files:** the menu still shows Inventory on `fees.view` (`Views/Shared/Sections/Menu/_VerticalMenu.cshtml:66`); it should be `Can("inventory.view")` |
| PERM-02 | Module toggle | `[RequiresModule(SchoolModule.Inventory)]` | controller | static `InventoryController.cs:13` | PASS |
| PERM-03 | Anti-forgery on every POST | | controller | static `InventoryController.cs:92,102,111,155,165,226,236` | PASS |

## UI / service (UI)

| ID | Finding | Where | Result |
|---|---|---|---|
| UI-01 | Purchase page summary cards are hard-coded (₹42,500, 18 bills, 560 items, 12 suppliers) | `PurchaseEntry.cshtml:40,46,52,58` | FIXED: cards show real figures (today's total, bills and quantity this month, supplier count), refreshed after save/cancel/add supplier |
| UI-02 | Item delete confirm passes `body/confirmText/confirmClass`. The item name and "history is kept" note are never shown | `InventoryItem.cshtml:691-696` | FIXED: `name` + `message` + okText "Delete item" |
| UI-03 | "Clear this purchase?" confirm: same wrong option names, button reads "Delete" | `PurchaseEntry.cshtml:433-437` | FIXED: "Clear this form?", okText "Clear form", `danger: false` |
| UI-04 | `Adjustment` labelled "physical count" but can only add | `InventoryItem.cshtml:315` | FIXED: Adjustment relabelled "add stock found"; Stock-take added |
| UI-05 | Item JSON in a script via `Html.Raw(JsonSerializer.Serialize(...))` | `PurchaseEntry.cshtml:277-280` | PASS: the default encoder escapes `<>&'"` |
| UI-06 | Purchase item picker lists Inactive items | `InventoryController.cs:36` (ListItems has no active filter) | FIXED: picker lists active items only |
| UI-07 | Raw DB errors shown to the user ("duplicate key value violates unique constraint ux_inventory_item_name", "numeric field overflow", "chk_inv_pi_tax") | `InventoryService.cs:291-297` | FIXED: `ILogger` added (Warning with SqlState / Error); raw database errors mapped to sentences; duplicates now caught in the procs with their own messages |
| UI-08 | `Purchases?from=abc` raises an uncaught `PostgresException` (500) | `InventoryService.cs:171-173` (`NpgsqlDbType.Unknown`, outside `RunAsync`) | FIXED: filter dates pass through `Dates.Norm` (bad text dropped); purchase date validated before the call |
| UI-09 | Lines with `ItemId <= 0` silently dropped | `InventoryService.cs:245` | FIXED: a line without an item is refused, not dropped |

---

## L. Store locations, transfers, returns to supplier, supplier screen (2026-10-10b)

**Suite:** `EduCoreDataAccessLayer/Database/tests/inventory_locations_tests.sql` (same harness,
fixture 24/34/39, other school 23/33, rolls back). It re-runs `../inventory.sql` twice inside its
transaction to test the migration.

```
export PGPASSWORD=root; "/c/Program Files/PostgreSQL/16/bin/psql.exe" -U postgres -d educore -q \
  -f EduCoreDataAccessLayer/Database/tests/inventory_locations_tests.sql 2>&1 | sed 's/^psql:[^ ]* NOTICE:  //'
```

**Result:** `RESULT: 111 passed, 0 failed`. After the rollback, 0 `ZZL%` rows are left.

**Rules under test:**
`current_stock = SUM(location stock) = SUM(ledger)`; per location, stock = SUM(ledger rows at it);
`balance_after` (item) and `location_balance_after` (location) are running sums; no location below 0.

**Decisions taken (document, not ask):**
- The default location ("Main Store") is created on first need, can be renamed, never deactivated.
  A movement, opening stock or bill with no location goes there.
- A location that still holds stock cannot be deactivated. Inactive locations take no movement,
  transfer or bill.
- A transfer needs a reason. The return movement type is `SupplierReturn` (`Return` already
  means "came back into the store").
- **Cancelling a bill that has returns reverses only the remainder** (bought - returned per line),
  at the bill's location. Refusing instead would leave a partly returned bill impossible to
  cancel; reversing the whole bill would take the returned goods out twice. Per line, Purchase +
  SupplierReturn + PurchaseCancel nets to 0. No return after a cancel. A fully returned bill
  cancels with no movement.
- Supplier deactivate is allowed; an inactive supplier keeps its bills but cannot take a new bill.
  Remove is a soft delete (existing behaviour). GSTIN must be 15 letters/digits, stored uppercase.

| ID | Scenario | Expected | Result |
|---|---|---|---|
| MIG-01..01b | Legacy school (rows written without locations) after the migration | exactly one default location, "Main Store" | PASS |
| MIG-02..02b | Legacy movements | all in the default location; none anywhere without a location | PASS |
| MIG-03 | Legacy bill | `location_id` = default | PASS |
| MIG-04..04c | Item totals | unchanged; = sum of location stock; Legacy A 35 at Main Store | PASS |
| MIG-05..05b | `location_balance_after` on old rows | back-filled as a running sum per location | PASS |
| MIG-06 | Whole database | every item: total = sum of locations | PASS |
| MIG-07..07b | Re-run the script | no new location / stock row / quantity / movement; `location_id` NOT NULL | PASS |
| LOC-01..05b | List, add (trimmed), duplicate (any case/spaces), blank, >100 chars, rename, rename onto another | as stated | PASS |
| LOC-06..06c, 09 | Cross-school rename / deactivate / list | refused / not listed; ours unchanged | PASS |
| LOC-07 | Deactivate the default | refused | PASS |
| LOC-08..08b | Deactivate a location holding stock; re-activate | refused with counts; re-activate works | PASS |
| LOC-10..12b | Opening stock: default, chosen, foreign (no half item), inactive location | as stated | PASS |
| LOC-13 | `ListItems` with a location | stock at that location | PASS |
| MVL-01..05 | Issue where none is held, issue to default, stock-take vs location stock, inactive / foreign location | refused by location name / default used / difference at that location / refused | PASS |
| TRF-01..01c | Transfer 10 Main → Lab | 35 / 10, total unchanged; one transfer row (who, trimmed reason); paired Out/In rows with rate | PASS |
| TRF-02..08c | More than the source holds (nothing written), same location, inactive item, inactive destination / source, 3 decimals, 0, blank reason, no destination, foreign location, other school's call | all refused, our stock untouched | PASS |
| TRF-09..12 | Transfer list (names, who), other school sees none, history shows location / other side / location balance, running sums, `ItemStock` | as stated | PASS |
| PUL-01..03b | Bill into the lab (rows at the lab), foreign location, inactive supplier refused then re-activated (no location → default) | as stated | PASS |
| RET-01..01c | Return 5 of a line | lab stock down, amount 210 (rate + tax), return row, `SupplierReturn` row linked to bill and line | PASS |
| RET-02..06b | More than bought - returned, same line twice summing over, blank reason, other bill's line, 3 decimals, 0 | refused | PASS |
| RET-07..07b | Return that would take the bill's location below 0; two-line return checked per item | refused by location name; accepted | PASS |
| RET-08..10 | Other school's return / read; `Get` header and lines with returned qty/amount; `Returns` list; `List` returned columns | refused / 0 rows / as stated | PASS |
| CWR-01..01b | Cancel when the remainder is no longer at the location | refused whole, nothing reversed | PASS |
| CWR-02..02c | Cancel with returns | only the remainder reversed, at the lab, with reason and line; per line nets to 0 | PASS |
| CWR-03..04 | Return after cancel; cancel a fully returned bill | refused; cancelled with no movement | PASS |
| SUL-01..07 | Bad email, bad GSTIN, GSTIN uppercased, inactive still listed, Active filter, search by mobile / GSTIN, bill count/total/last date (live bills), cross-school deactivate, soft delete keeps bill name, bills of one supplier | as stated | PASS |
| INV-01..06 | Three figures agree; pairs = ledger; running sums; table refuses location stock < 0; Recount (other school leaves ours, ours repairs); no proc deletes or edits ledger / lines / returns / transfers | as stated | PASS |
| CUR-01 | List and Cancel open the second cursor | FETCH works | PASS (was a live bug: the app FETCHes every refcursor, and an unopened one failed) |
| TEN-L1..L3 | Platform scope, other school's `ItemStock`, every location reference inside its own school | refused / 0 / 0 | PASS |

**UI (static + node syntax check of each inline script):** `InventoryItem` (location filter,
location on movement and opening stock, transfer dialog, per-location badges and location column
in history), `PurchaseEntry` ("goods go to", View → detail, return to supplier, cancel), new
`StoreLocations` and `SupplierMaster` pages and menu entries. Every DB string goes through
`EC.esc`; numeric attributes read with `.attr`. Not clicked through in a browser in this pass.

---

## Business decisions (approved defaults, applied 2026-10-10)

D-1 view/manage split, cancel = manage. D-2 Stock-take movement. D-3 value at cost price, labelled.
D-4 future refused, back-dated allowed, history in date order. D-5 reason required. D-6 Inactive items
cannot be issued or bought. D-7 no-supplier bills allowed, number unique among them. D-8 unit frozen once
stock moved. D-9 unchanged. D-10 transfers / partial returns: built 2026-10-10b (section L). D-11 at most 2 decimals.

The original questions:

| # | Question | Behaviour before the fix |
|---|---|---|
| D-1 | Which roles get `inventory.view` / `inventory.manage`, and should cancelling a purchase need a separate right (like `fees.cancel`)? | Everything gated on `fees.view` |
| D-2 | How does a stock-take that finds **less** stock get entered? Signed Adjustment, or a separate "Shortage" type? | Adjustment only adds; shortages must be entered as Damage |
| D-3 | Valuation basis: item standard cost (editable, no history), last purchase rate, or weighted average? Should the ledger carry a rate? | `current_stock × cost_price`. The ledger has no rate |
| D-4 | Lower bound for back-dated bills (e.g. current session only)? | Any past date. The ledger is in entry order, not date order |
| D-5 | Is a cancel reason mandatory server-side? | Optional in the proc, required only in the page |
| D-6 | Can Inactive items be issued or purchased? | Yes, both |
| D-7 | Is a purchase with no supplier allowed? If so, how is duplicate-bill protection done (PUR-05)? | Allowed; no duplicate guard |
| D-8 | Can an item's unit change once it has stock history? | Yes, silently re-labels history |
| D-9 | Should bill-number uniqueness key on supplier name/GSTIN rather than `supplier_id` (SUP-10)? | Keyed on `supplier_id` |
| D-10 | Are transfers between stores/departments and partial return-to-supplier needed? | Not supported; cancel is all-or-nothing |
| D-11 | Quantity precision: reject more than 2 decimals, or round on entry (MOV-01, PUR-17)? | Accepted unrounded, which drifts |
