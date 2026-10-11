# EduCore manual test guide (local)

Every page tested and fixed on 2026-10-10/11: **what the bug was, what changed, and how
to check it yourself.** The full test tables (with SQL check IDs) are in the other files in
this folder; this one is the hands-on checklist.

## 0. Before you start

1. **Local database is already up to date** (every script was applied while testing).
   Confirm `appsettings.Development.json` points at `localhost` (the Railway line stays
   commented).
2. **Restart the app** in Visual Studio (F5 / IIS Express) so it loads the new code:
   `https://localhost:44383`.
3. Log in as a **school admin**. For permission tests, also create a second login with a
   custom role (step 13).
4. All data is test data — create, edit and cancel freely.
5. Format below: **Bug** (what was wrong) → **Fix** → **Test** (steps) → **Expect**.

---

## 1. School Settings

### 1.1 Basic Profile — `/ERP/SchoolSettings/BasicProfile`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Changing state kept the old state's district | Change State to another state, leave District blank, Save, reload | District is empty (not the old one) |
| 2 | Website `school.com` passed the page but failed on save | Website = `school.com`, Save | Saves as `https://school.com` |
| 3 | A `.jfif` logo crashed the page (500) | Upload a `.jfif` / `.gif` | Clear message: only jpg/jpeg/png/webp |
| 4 | Server accepted an established year up to 2100 | Established year = next year | "Enter valid established year" |
| 5 | After a validation error the sidebar showed "Tenant not available" | Make any field invalid and Save | Error shows, sidebar still shows tenant/status/board |
| 6 | **New:** Remove logo | With a logo saved, click **Remove logo** → confirm | Logo gone, default image shows; file deleted from `wwwroot/uploads/schools/<t>/<s>/` |
| 7 | **New:** landline accepted | Official Phone = `0141-2345678`, Save, reload | Saved as `01412345678`. `12345` or `abc` is refused |

### 1.2 Documents — `/ERP/SchoolSettings/Documents`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Default TC format was never used | Set TC format = Board, then Students → Inactive → issue TC | The TC dialog opens on **Board** |
| 2 | Permission errors showed "Something went wrong" | Save a format as a user without fees.manage | "You do not have permission to do this." |

### 1.3 Academic Years — `/ERP/SchoolSettings/AcademicYears`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | "Set current" on a stale/deleted id left the school with **no** current session | Set current on another year, then try to delete the current one | Exactly one current always; the delete button is hidden on the current row |
| 2 | Unticking "current" while editing left none | Edit the current year, try to untick Current | Switch disabled with a note |
| 3 | Renaming a session cut its students loose | Rename a session that has students | Refused ("in use"); dates still editable |
| 4 | Overlapping sessions accepted | New year whose dates overlap an existing one | Refused |
| 5 | Raw DB errors (blank dates, end = start, name > 20 chars) | Try each | Readable message each time |
| 6 | A deleted session's name could not be reused | Delete an unused year, create one with the same name | Works |

### 1.4 Admission Workflow — `/ERP/AdmissionWorkflow/WorkflowSettings`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Typing an existing head's name on a fee card took over that head (e.g. "Admission Fee" became a refundable deposit) | On the Security Deposit card type `Admission Fee`, amount 500, Save | Refused: "A fee head called … already exists" |
| 2 | Saving on a deactivated head left it inactive (registration charged 0) | Deactivate the Registration head in Fee Head, save an amount on its card | Head is active again |
| 3 | If settings failed to load, Save overwrote them with defaults | (hard to trigger) | Red banner + Save disabled when load fails |
| 4 | Duplicate manual registration numbers | Auto-number off, register two enquiries with the same number | Second refused |

### 1.5 Classes & Sections — `/ERP/SchoolSettings/ClassSection`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Any Save wiped subjects, exam papers and the timetable** (new ids every save) | Note a class's subjects; press Save with **no change** | Subject Management still shows the same subjects; timetable intact |
| 2 | Renaming a class lost its fee structure / class teacher | Rename a class with no students | Fee structure and class teacher follow the new name |
| 3 | Rank 0 / bad capacity accepted | Rank 0, capacity -5 | Refused |
| 4 | Saving a class with students removed | Remove a class that has students | Refused |

### 1.6 Subject Management — `/ERP/SchoolSettings/SubjectManagement`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Subjects saved for next session went into the current one | Pick next session, add subjects to a class, Save, reload that session | Subjects show under next session |
| 2 | Classes named "1"–"8" could not be opened | Open class `5` | Pills load |
| 3 | Stored XSS in a subject name | Add subject `x" onmouseover="alert(1)` | Shown as plain text, nothing runs |
| 4 | Unsaved edits looked saved after switching class | Add a subject, switch class, come back | "Unsaved" badge still shows; Discard works |
| 5 | Removing a subject left its timetable bookings | Remove a subject that is booked | Its timetable cells are cleared |

### 1.7 Assign Class Teacher — `/ERP/SchoolSettings/AssignClassTeacher`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Drivers/accountants could be class teachers | Open the teacher dropdown | Only active **teaching** staff |
| 2 | Inactive teacher showed as "Unassigned" | Deactivate an assigned teacher, reload | Shows "<name> (inactive)" |
| 3 | Another school's staff id accepted (API) | — | Refused by the proc |

### 1.8 Period Structure — `/ERP/SchoolSettings/PeriodStructure`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Adding an assembly **shifted every timetable lesson** | Book Monday P1 Maths; add an Assembly before P1; Save | Maths stays on P1 |
| 2 | Removing a period with lessons orphaned them | Delete a booked period, Save | Refused, names the period |
| 3 | Up/down buttons made fake overlaps | — | Buttons removed (order = clock time) |
| 4 | **New:** per-weekday schedule | Saturday tab → Custom schedule → keep 4 periods → Save | Timetable shows only 4 periods on Saturday; Smart Bell follows it |
| 5 | **New:** Use default | Saturday → Use default | Saturday back to the default schedule |
| 6 | Leaving with unsaved changes gave no warning | Edit, then close the tab | Browser warns |

### 1.9 Fee Head — `/ERP/SchoolSettings/FeeHead`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Renaming a head rewrote other schools' receipts** | (multi-school) Rename a head | Only this school's receipts change |
| 2 | No way to deactivate a head | Use the toggle on a row | Inactive badge; toggle back works |
| 3 | Cycle saved as typed (" monthly ") broke Fee Structure | Save cycle `monthly` | Stored as `Monthly` |
| 4 | Fee type not validated | (API) "Compulsory" | Refused |
| 5 | Search not trimmed; `%` matched everything | Search ` tuition ` and `%` | Trimmed match; `%` literal |
| 6 | Cycle change didn't reach saved structures | Change a head's cycle | Message says how many structures were updated |

### 1.10 Fee Structure — `/ERP/SchoolSettings/FeeStructure`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Negative amount accepted** (negative totals into the ledger) | Amount `-500`, Save | Refused |
| 2 | **Search broke on numeric class names** | Saved Structures search `5` | Filters correctly |
| 3 | Editing a structure with an inactive head dropped that head | Deactivate a head used in a structure, Edit, Update | Head kept (shown in "Inactive heads" block) |
| 4 | Posted head name/cycle trusted; another school's head id accepted | (API) | Refused / taken from master |
| 5 | Totals drifted from lines (rounding) | Amounts like `2500.333` | Totals = sum of rounded lines |
| 6 | Quarterly / Half Yearly missing from summary | Add such heads | Rows appear in summary |
| 7 | Session dropdown didn't reload classes; Reset didn't exit edit mode | Change session; Edit then Reset | Classes reload; Reset leaves edit mode |
| 8 | "Created/Updated by" showed a number | Look at a saved row | Shows user name |
| 9 | No delete | Delete a structure (confirm) | Deleted; "not found" shows a real error |
| 10 | XSS via head/class names in summary | Head named `<b>x</b>` | Shown as text |

### 1.11 School Calendar — `/ERP/SchoolSettings/SchoolCalendar`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Page did not load** (date stored as text) | Open page | Loads with holidays/weekly offs |
| 2 | **New:** date range | Date range → Holiday 20–25 Dec | One entry per day; weekly offs skipped; existing days skipped and listed |
| 3 | **New:** delete range | Remove the same range | All gone |
| 4 | Half-day closing time outside school hours | Half day closing 18:00 | Refused |

### 1.12 Timetable / Smart Bell
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Save checked almost nothing | Book: a subject the class doesn't study; an inactive or non-teaching teacher; a weekly off; a busy room | Each refused |
| 2 | Copy Day across different schedules | Copy Monday → short Saturday | Only matching periods copied; skipped ones listed |

### 1.13 Staff Masters / Grade Scale
- **Staff Masters:** rename a designation → staff rows follow; delete and re-add a name → works; staff type is a dropdown.
- **New Grade Scale** (`Examinations → Grade Scale`): edit bands; gaps/overlaps/duplicate labels refused; "Reset to CBSE" works.

---

## 2. Enquiry & Registration — `/ERP/Enquiry/EnquiryCRM`, `/ERP/Registration`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **"Mark fee collected" marked paid with no receipt** | Registrations → collect fee | A real receipt is created; paid status comes only from receipts |
| 2 | Browser's "fee paid" tick trusted | Register with the tick but no amount | Not marked paid |
| 3 | **Fee could be collected again after admission** | Admit a registered child, try to collect the registration fee again | Refused |
| 4 | Deleting an enquiry that holds money | Enquiry with a receipt → Delete | Button hidden / refused; history row written |
| 5 | Part payments: only the last receipt reprintable | Pay 200 + 300, open receipts | Both listed and reprintable |
| 6 | No way to cancel a wrong registration receipt | Receipts dialog → Cancel (reason) | Cancelled, balance back |
| 7 | Discount without a reason; percentage stored as 0 | Discount 10% without reason | Refused; with reason, value stored |
| 8 | Receipt showed cash + discount as paid | Pay 400 with 100 discount, print | "Paid" 400, discount on its own line |
| 9 | Payment mode `cash` dropped from Day Close | (API) | Normalised to Cash |
| 10 | Future-dated receipt accepted | (API) | Refused |
| 11 | Permission: taking money needs `fees.collect` | Register-with-fee as a role without it | "You do not have permission to collect fees" |

## 3. Admission — `/ERP/Admission/Create`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Payment failure at admission was silent | (hard to trigger) | Warning dialog stays on screen |
| 2 | Plan/amounts trusted from the browser | (API) | Rebuilt on the server from the fee structure |
| 3 | "Security Deposit" fallback had a wrong name (not refundable later) | Admit with deposit, later Refund screen | Deposit shows as refundable |
| 4 | Annual concession misapplied | Concession "Apply to: Estimated Annual" | Spread proportionally |
| 5 | Over-cap concession posted at once | Concession above the cap | Not posted; "awaiting approval" message |
| 6 | Same enquiry admitted twice | Admit the same enquiry twice | Second refused |
| 7 | Bus billed with Transport module off | Turn Transport off in Workflow, admit | No route offered, no bus dues |
| 8 | Aadhaar / roll number | 11-digit Aadhaar; duplicate roll in section | Both refused |

## 4. Fee counter — `/ERP/Fee/ManageFee`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Same due twice / two counters over-collected** | (API) | Lines merged, rows locked |
| 2 | Cheque/UPI reference couldn't be recorded | Cash + Cheque split | Reference box per tender; cheque number required |
| 3 | Reprint of a cancelled receipt looked valid | Cancel a receipt, reprint | **CANCELLED** banner, who/when/why |
| 4 | Receipt printed "Mixed" | Pay Cash 2000 + UPI 1000, reprint | "Cash 2000 + UPI 1000", cashier name |
| 5 | **Cancel after refund reversed money twice** | Refund a deposit, then cancel its receipt | Refused |
| 6 | Cancel after the advance was spent → negative wallet | Overpay → advance, spend it, cancel first receipt | Refused |
| 7 | Concession with no reason / no approver | Discount without reason or "Approved by" | Refused |
| 8 | Discount could land on a refundable deposit | Select a deposit + tuition, give a discount | Deposit shows "refundable" tag; discount goes only on tuition |
| 9 | Refunds invisible on History | Refund something | Listed in History; voucher reprints |
| 10 | No wallet refund | Student with advance → Refund → wallet | Voucher created, wallet 0 |
| 11 | Extras-only collection impossible | Collect only an extra charge (fine) | Works |
| 12 | Collecting after Day Close | Close today, then collect | "Today is already closed…" |
| 13 | Permissions split | Role with fees.collect but not fees.cancel | Can collect, cannot cancel |

## 5. Day Close — `/ERP/Fee/DayClose`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Expected cash wrong for Cash+UPI / overpay / wallet** | Cash 2000 + UPI 1000 receipt | Expected cash rises by 2000 only |
| 2 | **Closed day not locked** | Close day, try to collect or cancel | Refused until **Re-open day** (reason) |
| 3 | Cancel counts on the cancel day | Cancel yesterday's receipt today | Yesterday unchanged; today shows a negative row |
| 4 | Re-close overwrote the first count | Close → Re-open → Close | Close history shows both counts |
| 5 | Future date / negative cash accepted | Try both | Refused |

## 6. Reports, reminders, dashboard
| Page | Test | Expect |
|---|---|---|
| Collection Register | Mixed-tender receipt; a cancellation | Real split per mode (no "Mixed"); cancellation as a red negative row on its cancel day; "By" column; class/section filter |
| Concessions & Cancellations | Registration discount | Listed with who gave it; CSV export |
| Refund register | — | Shows who refunded |
| Defaulters | Family paid up to today | **Not listed** (only fallen-due counts). **New** session dropdown with "All sessions"; exited students listed while they owe |
| Fee Due Reminders | Select a small debtor among many; export | Not dropped; export not capped at 200 |
| Dashboard | Student with several receipts | "Highest outstanding" not multiplied. Money cards hidden for a role without `fees.view` |

## 7. Students
| # | Page / Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | Promotion: **unticked students still promoted** | Untick 2 of 10, promote | Only 8 move; new-session fees billed; re-run doesn't double-bill |
| 2 | Promotion roster listed already-moved children | Reload roster after promoting | They're gone; empty sections offered |
| 3 | Edit Student silently dropped fields; future DOB accepted | Edit DOB to tomorrow; mobile `98AB5` | Refused; status change moved to Exit flow |
| 4 | No edit history | Change mobile, open Student Dashboard | "Activity & Money History" shows old → new |
| 5 | Dashboard XSS + fake address "Village Mathura" | Guardian name `<b>x</b>`; open dashboard | Text shown; real address |
| 6 | Exit left future dues and bus | Exit with a leaving date | Later dues closed "Left on <date>"; bus ended; Reactivate restores |
| 7 | TC with money in the wallet | Issue TC to a student with advance | Refused until wallet refunded |
| 8 | **Voided TC printed clean**; Issue & Print 404 | Void a TC, print; Issue & Print | VOID stamp; print opens; refresh doesn't use up the original |
| 9 | Directory search/sort/export | Double spaces, `%`, sort by class, CSV with `=1+1` name | Works; class order LKG→12; cell neutralised |
| 10 | Photo | Replace a photo | Old file deleted; change audited |
| 11 | ID cards | Section with missing photos | Missing list shown before printing |

## 8. Transport — `/ERP/Transport/*`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Assign page couldn't show/remove a bus** | Open a student who has a bus | "Currently assigned" + Remove work |
| 2 | Route full | Assign beyond vehicle capacity | Refused "X of Y seats" |
| 3 | Last vehicle of a route with riders switched off | Deactivate it | Refused |
| 4 | Route/stop with riders deleted | Delete | Refused |
| 5 | Duplicates / negatives | Same route name, same vehicle no., fare -10, capacity 0 | All refused |
| 6 | Removing a bus hard-deleted dues | Remove mid-year | Future dues closed with a reason, not deleted |

### 8.1 Live bus tracking — `/ERP/MyBus`, `/ERP/Transport/LiveTracking`, `/ERP/Transport/TripHistory`, `/BusTrack/{token}`

**Setup.** Give a staff member a login, then on **Vehicles** pick that staff member as the bus's
**Driver**. Sign in as that user: "My Bus" appears in the menu (it can take up to 5 minutes to
appear after the driver is changed).

**Location without driving around.** Location needs `https://` or `localhost`.
- *Desktop:* open `https://localhost:7230/ERP/MyBus` (or F5 / IIS Express) in Chrome → DevTools →
  ⋮ → More tools → **Sensors** → Location: pick a city or type lat/lng. Change it every
  20–30 s to "move" the bus. Allow location when the browser asks.
- *Phone on the same Wi-Fi:* the phone needs https. Easiest is Android Chrome with USB debugging
  and `chrome://inspect` → **Port forwarding** `7230 → localhost:7230`, then open
  `https://localhost:7230` on the phone. A plain `http://<pc-ip>:5055` will NOT get location
  (not a secure context); the page then says "Location needs an https:// page".

| # | Test | Expect |
|---|---|---|
| 1 | Sign in as a user who drives no bus, open `/ERP/MyBus` | "You are not the driver of any bus." |
| 2 | As the driver: **Start Trip** | Green button turns into red **End Trip**; yellow "keep this page open" banner; GPS "OK · ±N m"; "Points sent" rises about every 15 s |
| 3 | Reload the page mid-trip | Trip carries on (same trip, sending resumes) |
| 4 | Second browser as office staff: **Live Tracking** | Bus marker with its number; list shows route, driver, "just now"; refreshes every 10 s; click a list row → map zooms to the bus |
| 5 | Stop changing the location / close the driver tab for 3+ min | Marker and row turn grey ("3 min ago") |
| 6 | Leave it 30+ min | Trip disappears from Live Tracking; Trip History shows it "(auto-ended)" |
| 7 | **End Trip** | Bus leaves the live map within 10 s |
| 8 | **Trip History**: pick the bus and today, click the map button | Orange path with green start and red end; **Replay** moves a dot along it |
| 9 | **Routes** → "Create parent tracking link" | Modal with the link, Copy link, WhatsApp/SMS message. Close → card says "Parent link on" |
| 10 | Open the link in a private window (no login) | Route name; "The bus is not on a trip right now" — then start a trip: the bus appears within 15 s. No driver name or phone anywhere |
| 11 | Routes → **New link**, then refresh the old link | Old link: "not valid or has been turned off"; new link works |
| 12 | **Turn off** | The open parent page switches to "This tracking link has been turned off." on its next refresh |
| 13 | Switch Transport off (Admission Workflow) | Live Tracking / Trip History redirect to settings; My Bus says Transport is off; parent link shows "not valid" |
| 14 | Refresh the parent link 70 times in a minute | 429 after 60 — the limit is per IP |

## 9. Attendance & Exams
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Exam create/edit failed** | Create an exam | Saves |
| 2 | Class teacher could mark any student | Mark 7-A as 7-A's teacher | Only 7-A roster accepted; inactive teacher blocked |
| 3 | Attendance ignored calendar | Mark on a declared holiday / weekly off | Refused; declared working Sunday allowed |
| 4 | % wrong for mid-month joiner / section change (could be 150%) | Check a joiner's % | Counts only days since joining |
| 5 | Leave/Late turned into Present | Mark Leave, reload | Stays Leave |
| 6 | Finalise didn't make blanks Absent | Leave a cell blank, Finalise | Becomes Absent |
| 7 | **Multi-class exam results wrong** | Exam for 6 and 7 with shared Maths | Each class's % correct |
| 8 | Paper removed after marks / max below marks | Try both | Refused |
| 9 | Edit history | Change a mark/attendance | History table has old → new, who, when |
| 10 | **New:** publish results | Result Sheet → Publish (all sheets finalised) | Student dashboard shows result only after publish; marks locked; Unpublish needs reason |
| 11 | **New:** grades & rank | Result Sheet | Grade per subject/overall; ties share rank (1,1,3); print + CSV |

## 10. Staff, Leave, Payroll
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Edit Staff never saved** | Edit any staff field, Save | Saved |
| 2 | Inactive staff could still log in | Mark staff Inactive (last working day) | Their login stops; reactivate restores |
| 3 | Duplicate employee code (case) / negative salary | Try | Refused |
| 4 | Leave counted Sundays / holidays; no cap; no half day | Apply leave across a holiday; exceed Casual 12 | Only working days counted; over-cap → Unpaid; half day works |
| 5 | No cancel | Cancel approved future leave (reason) | Cancelled with who/when |
| 6 | Payroll pro-rata / LOP | Run payroll for a mid-month joiner | Pro-rata pay; exact loss of pay |
| 7 | Mark Paid without mode | Mark Paid | Mode required; reference unless Cash |
| 8 | Paid slip could be changed | Re-run a paid month | Paid slips untouched; difference reported |
| 9 | **New:** adjustments | Add Addition/Deduction/Advance | Recorded with reason/who/when |
| 10 | **New:** payroll permission | Role with staff.manage but not payroll.view | No Payroll menu; salary hidden on Staff Profile |

## 11. Inventory — `/ERP/Inventory/*`
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Purchase list/save/cancel failed in the app** (live too) | Open Purchases, save a bill, cancel it | All work |
| 2 | **Cancel with the same item on two lines broke stock** | Bill item A 30 + 20, issue 15, cancel | Refused (would go below 0) |
| 3 | Wrong permission (fees.view) | Role with only inventory.view | Can view, cannot save |
| 4 | 3-decimal qty drift; negative opening/cost | Qty 0.335; opening -5 | Refused |
| 5 | Fake summary cards (₹42,500 etc.) | Purchase page | Real figures |
| 6 | Stock-take | Stock-take with a lower count + reason | Stock reduced, recorded |
| 7 | **New:** locations | Add "Science Lab" | Existing stock is in "Main Store" |
| 8 | **New:** transfer | Main Store → Science Lab 5 | Paired movement with who/when; can't exceed source |
| 9 | **New:** return to supplier | From a bill, return 3 of a line (reason) | Stock reduced; can't exceed bought − returned |
| 10 | **New:** suppliers screen | Add/edit/deactivate | Inactive supplier not offered on new bills |

## 12. Login, roles, platform
| # | Bug → Fix | Test | Expect |
|---|---|---|---|
| 1 | **Custom roles couldn't log in** | Create role "Cashier", give a user only that role, log in | Logs in |
| 2 | **Old session survived deactivation / password reset** | Logged in in browser A; deactivate that user (or reset password) in browser B | Browser A signed out within ~1 min |
| 3 | Hidden "Super Admin" role | Create role named "Super Admin" | Gets a non-reserved code, no bypass |
| 4 | Reset revealed which emails exist | Forgot password with a fake email + wrong code | Same message as a real email |
| 5 | Last school admin removable; self role change | Try to remove the only admin / change own role | Refused |
| 6 | Login limit counted correct logins | 10 wrong passwords from one machine | 11th blocked ~5 min; correct logins never counted |
| 7 | Roles page | Open a role | Fees row has extra ticks: Collect, Cancel, Refund, Concessions; Inventory and Payroll rows exist |
| 8 | Audit | Change a role's permissions | `core.admin_activity_logs` row with old → new |

## 13. Setting up a permission test user
1. Roles → New role "Cashier" → tick Fees View + **Collect** only.
2. Staff → add a staff member with a login, role Cashier.
3. Log in as them in another browser: can collect, cannot cancel/refund/discount; no
   Inventory/Payroll menus.

## 14. Automated re-check (2 minutes)
Run every SQL suite against local; all should say `0 failed`:

```bash
cd D:/Github/EduCoreLiveV1/EduCoreDataAccessLayer/Database/tests
export PGPASSWORD=root
for s in *.sql; do echo -n "$s: "; "/c/Program Files/PostgreSQL/16/bin/psql.exe" -U postgres -d educore -q -f $s 2>&1 | grep -oE "RESULT: .*"; done
```
