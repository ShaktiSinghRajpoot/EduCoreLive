/* ============================================================
   EduCore — Shared Inventory Catalog (single source of truth)
   ------------------------------------------------------------
   All inventory-aware screens read items from here instead of
   keeping their own hard-coded copies:
     • Inventory Item Master  (ERP/Fee/InventoryItem)
     • Purchase Entry         (ERP/Fee/PurchaseEntry)
     • New Admission kit      (ERP/Student/StudentList)

   This is the prototype seed. When a backend exists, replace the
   `items` array with an API fetch and keep the same public API so
   the pages don't have to change.
   ============================================================ */
window.EduInventory = (function () {
    "use strict";

    // id, name, code(SKU), category, subCategory, type, unit, brand, model,
    // stock, minimum, cost, selling, status
    // sellable      → can be sold to a student (store / admission)
    // admissionKit  → offered as an add-on during New Admission
    // mandatory     → kit item pre-ticked / required at admission
    var items = [
        { id: 1,  name: "Uniform Set",          code: "UNI-SET-001",   category: "Uniform",    subCategory: "Full Set",      type: "Saleable",   unit: "Set",   brand: "EduCore", model: "Standard", stock: 60,  minimum: 15, cost: 480, selling: 650, status: "Active", sellable: true,  admissionKit: true,  mandatory: false },
        { id: 2,  name: "Tie & Belt",           code: "UNI-TB-001",    category: "Uniform",    subCategory: "Accessory",     type: "Saleable",   unit: "Set",   brand: "EduCore", model: "Standard", stock: 140, minimum: 30, cost: 70,  selling: 120, status: "Active", sellable: true,  admissionKit: true,  mandatory: false },
        { id: 3,  name: "School Diary",         code: "STA-DIARY-001", category: "Stationery", subCategory: "Diary",         type: "Saleable",   unit: "Piece", brand: "EduCore", model: "2026",     stock: 200, minimum: 50, cost: 50,  selling: 80,  status: "Active", sellable: true,  admissionKit: true,  mandatory: false },
        { id: 4,  name: "ID Card",              code: "STA-ID-001",    category: "Stationery", subCategory: "Identity",      type: "Saleable",   unit: "Piece", brand: "EduCore", model: "PVC",      stock: 500, minimum: 80, cost: 30,  selling: 60,  status: "Active", sellable: true,  admissionKit: true,  mandatory: false },
        { id: 5,  name: "School Tie",           code: "UNI-TIE-001",   category: "Uniform",    subCategory: "Tie",           type: "Saleable",   unit: "Piece", brand: "EduCore", model: "Standard", stock: 120, minimum: 25, cost: 45,  selling: 80,  status: "Active", sellable: true,  admissionKit: false, mandatory: false },
        { id: 6,  name: "School Belt",          code: "UNI-BELT-001",  category: "Uniform",    subCategory: "Belt",          type: "Saleable",   unit: "Piece", brand: "EduCore", model: "Standard", stock: 100, minimum: 25, cost: 50,  selling: 90,  status: "Active", sellable: true,  admissionKit: false, mandatory: false },
        { id: 7,  name: "Class 10 Physics Book",code: "BOOK-PHY-10",   category: "Books",      subCategory: "Academic Book", type: "Saleable",   unit: "Piece", brand: "NCERT",   model: "2026",     stock: 18,  minimum: 20, cost: 140, selling: 180, status: "Active", sellable: true,  admissionKit: false, mandatory: false },
        { id: 8,  name: "Notebook",             code: "STA-NB-200",    category: "Stationery", subCategory: "Notebook",      type: "Consumable", unit: "Piece", brand: "Classmate",model: "200pg",    stock: 300, minimum: 60, cost: 25,  selling: 40,  status: "Active", sellable: true,  admissionKit: false, mandatory: false },
        { id: 9,  name: "Football",             code: "SPT-FB-001",    category: "Sports",     subCategory: "Ball",          type: "Reusable",   unit: "Piece", brand: "Nivia",   model: "Size 5",   stock: 24,  minimum: 8,  cost: 300, selling: 450, status: "Active", sellable: true,  admissionKit: false, mandatory: false },
        { id: 10, name: "Chemistry Lab Beaker", code: "LAB-BEAKER-250",category: "Lab Items",  subCategory: "Glassware",     type: "Reusable",   unit: "Piece", brand: "Borosil", model: "250ml",    stock: 0,   minimum: 10, cost: 95,  selling: 0,   status: "Active", sellable: false, admissionKit: false, mandatory: false }
    ];

    function clone(arr) { return arr.map(function (x) { return Object.assign({}, x); }); }

    return {
        /** Every catalog item (fresh copy, safe to mutate per-page). */
        all: function () { return clone(items); },
        /** Items that can be sold to a student (store / admission). */
        sellable: function () { return clone(items.filter(function (i) { return i.sellable && i.status === "Active"; })); },
        /** Items offered as add-ons during New Admission. */
        admissionKit: function () { return clone(items.filter(function (i) { return i.admissionKit && i.status === "Active"; })); },
        /** Look up one item by exact name. */
        byName: function (name) { var f = items.find(function (i) { return i.name === name; }); return f ? Object.assign({}, f) : null; },
        /** Selling price for a named item (0 if unknown). */
        priceOf: function (name) { var f = this.byName(name); return f ? Number(f.selling || 0) : 0; }
    };
})();
