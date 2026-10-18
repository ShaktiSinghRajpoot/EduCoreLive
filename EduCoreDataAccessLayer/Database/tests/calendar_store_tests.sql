-- School Calendar events, and books & uniform sold to a student (18 Oct 2026).
-- QA Test School (tenant 32, school 45, admin 62). Shreya Agarwal (725) is in
-- Class 7 for 2026-27 and already promoted to Class 8 for 2027-28.
-- Everything is ROLLED BACK. Run from this folder:
--     psql ... -f calendar_store_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (COALESCE(p_ok, FALSE), p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

CREATE FUNCTION pg_temp.sale(p_op text, p_student int DEFAULT NULL, p_year text DEFAULT NULL, p_class text DEFAULT NULL,
                             p_items jsonb DEFAULT NULL, p_line int DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ss'; r record;
BEGIN
    CALL core.sp_inventory_student_sale(p_op, 32, 45, 62, p_student, p_year, p_class, NULL, p_items, p_line, p_reason, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE FUNCTION pg_temp.ev(p_op text, p_id int DEFAULT NULL, p_title text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ev'; r record;
BEGIN
    CALL academic.sp_school_events_manage(p_op, 32, 45, 62, p_id, p_title, 'PTM', p_from, p_to, '10:00', '13:00', 'Class 1-5 parents', NULL, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

DO $t$
DECLARE
    v_loc int; v_book int; v_shirt int; v_txt text; v_n int; v_m int; v_amt numeric; v_line int; v_ev int;
    c refcursor; r record;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '== Calendar events ==';
    v_txt := pg_temp.ev('Save', NULL, 'ZZ PTM Term 1', DATE '2026-11-14', DATE '2026-11-14');
    SELECT event_id INTO v_ev FROM academic.school_events WHERE tenant_id = 32 AND title = 'ZZ PTM Term 1';
    PERFORM pg_temp.chk(v_ev IS NOT NULL, 'E1 event saved', v_txt);
    c := 'l1'; v_n := 0; v_m := 0;
    CALL academic.sp_school_events_manage('List', 32, 45, 62, p_start_date => DATE '2026-11-01', p_end_date => DATE '2026-11-30', p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.id = v_ev AND r.kind = 'Event' THEN v_n := v_n + 1; v_txt := r.start_time || '-' || r.end_time || ' ' || r.for_whom; END IF;
        IF r.kind = 'Exam' THEN v_m := v_m + 1; END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n = 1, 'E2 November lists it, with time and who', v_txt || ' (+' || v_m || ' exam period(s))');
    BEGIN
        v_txt := pg_temp.ev('Save', NULL, 'ZZ bad', DATE '2026-11-14', DATE '2026-11-10');
        PERFORM pg_temp.chk(FALSE, 'E3 an event cannot end before it starts', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'E3 an event cannot end before it starts', SQLERRM); END;
    BEGIN
        CALL academic.sp_school_events_manage('Delete', 23, 33, 62, v_ev, p_result => c);
        PERFORM pg_temp.chk(FALSE, 'E4 another school cannot delete it', 'deleted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'E4 another school cannot delete it', SQLERRM); END;
    v_txt := pg_temp.ev('Delete', v_ev);
    PERFORM pg_temp.chk((SELECT is_deleted FROM academic.school_events WHERE event_id = v_ev), 'E5 delete hides it (kept for the record)', v_txt);

    RAISE NOTICE '';
    RAISE NOTICE '== Books & uniform ==';
    v_loc := core.fn_inventory_default_location(32, 45, 62);
    INSERT INTO core.inventory_items (tenant_id, school_id, item_name, category, item_type, unit_type, cost_price, selling_price, created_by)
    VALUES (32, 45, 'ZZ Maths Book Class 8', 'Books', 'Saleable', 'Piece', 300, 450, 62) RETURNING item_id INTO v_book;
    INSERT INTO core.inventory_items (tenant_id, school_id, item_name, category, item_type, unit_type, cost_price, selling_price, created_by)
    VALUES (32, 45, 'ZZ Shirt - 32', 'Uniform', 'Saleable', 'Piece', 250, 400, 62) RETURNING item_id INTO v_shirt;
    PERFORM core.fn_inventory_post_movement(32, 45, 62, v_book,  v_loc, 'Opening', 10, 300);
    PERFORM core.fn_inventory_post_movement(32, 45, 62, v_shirt, v_loc, 'Opening', 5, 250);

    v_txt := pg_temp.sale('SaveKit', NULL, NULL, 'Class 8', jsonb_build_array(jsonb_build_object('itemId', v_book, 'qty', 1)));
    c := 'it'; v_n := 0;
    CALL core.sp_inventory_student_sale('Items', 32, 45, 62, p_class => 'Class 8', p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.item_id = v_book AND r.kit_qty = 1 AND r.in_stock = 10 THEN v_n := 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n = 1, 'S1 Class 8 set: the maths book, 10 in stock', v_txt);

    c := 'st'; v_txt := '';
    CALL core.sp_inventory_student_sale('Student', 32, 45, 62, p_student_id => 725, p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.academic_year || ' ' || r.class_name || CASE WHEN r.is_current THEN ' (now)' ELSE '' END || '; '; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_txt LIKE '%2026-27 Class 7 (now)%2027-28 Class 8%', 'S2 Shreya: this session and next', v_txt);

    v_txt := pg_temp.sale('Sell', 725, '2027-28', NULL,
        jsonb_build_array(jsonb_build_object('itemId', v_book, 'qty', 1), jsonb_build_object('itemId', v_shirt, 'qty', 2)));
    SELECT COUNT(*), SUM(amount_due) INTO v_n, v_amt FROM core.student_ledger
     WHERE student_id = 725 AND academic_year = '2027-28' AND frequency = 'One Time' AND due_date = to_char(CURRENT_DATE, 'YYYY-MM-DD')
       AND installment_label IN ('ZZ Maths Book Class 8', 'ZZ Shirt - 32 × 2');
    PERFORM pg_temp.chk(v_n = 2 AND v_amt = 1250, 'S3 sold: 2 fee lines in 2027-28, due today, Rs 1250', v_txt);
    PERFORM pg_temp.chk((SELECT current_stock FROM core.inventory_items WHERE item_id = v_shirt) = 3
                        AND (SELECT current_stock FROM core.inventory_items WHERE item_id = v_book) = 9, 'S4 stock went down (shirts 5 -> 3, books 10 -> 9)');
    PERFORM pg_temp.chk((SELECT fee_head_name FROM core.student_ledger WHERE student_id = 725 AND installment_label = 'ZZ Shirt - 32 × 2') = 'Uniform',
                        'S5 fee head is the item category (Uniform)');

    BEGIN
        v_txt := pg_temp.sale('Sell', 725, '2026-27', NULL, jsonb_build_array(jsonb_build_object('itemId', v_shirt, 'qty', 4)));
        PERFORM pg_temp.chk(FALSE, 'S6 cannot sell more than in stock', 'sold');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S6 cannot sell more than in stock', SQLERRM); END;
    BEGIN
        v_txt := pg_temp.sale('Sell', 725, '2025-26', NULL, jsonb_build_array(jsonb_build_object('itemId', v_book, 'qty', 1)));
        PERFORM pg_temp.chk(FALSE, 'S7 cannot sell for a session she is not in', 'sold');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S7 cannot sell for a session she is not in', SQLERRM); END;

    SELECT l.line_id INTO v_line FROM core.inventory_student_sale_lines l WHERE l.item_id = v_shirt ORDER BY l.line_id DESC LIMIT 1;
    v_txt := pg_temp.sale('Return', NULL, NULL, NULL, NULL, v_line, 'Wrong size');
    PERFORM pg_temp.chk((SELECT amount_due - amount_paid - concession FROM core.student_ledger
                          WHERE ledger_id = (SELECT ledger_id FROM core.inventory_student_sale_lines WHERE line_id = v_line)) = 0
                        AND (SELECT current_stock FROM core.inventory_items WHERE item_id = v_shirt) = 5,
                        'S8 return: off the fee account, shirts back to 5', v_txt);
    BEGIN
        v_txt := pg_temp.sale('Return', NULL, NULL, NULL, NULL, v_line, 'again');
        PERFORM pg_temp.chk(FALSE, 'S9 cannot return twice', 'returned');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S9 cannot return twice', SQLERRM); END;

    -- the book is paid (as Collect Fees would), so it cannot simply be returned
    SELECT l.line_id INTO v_line FROM core.inventory_student_sale_lines l WHERE l.item_id = v_book ORDER BY l.line_id DESC LIMIT 1;
    UPDATE core.student_ledger SET amount_paid = amount_due, status = 'Paid'
     WHERE ledger_id = (SELECT ledger_id FROM core.inventory_student_sale_lines WHERE line_id = v_line);
    BEGIN
        v_txt := pg_temp.sale('Return', NULL, NULL, NULL, NULL, v_line, 'Not needed');
        PERFORM pg_temp.chk(FALSE, 'S10 a paid item cannot be returned before its receipt is cancelled', 'returned');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S10 a paid item cannot be returned before its receipt is cancelled', SQLERRM); END;

    c := 'ls'; v_n := 0;
    CALL core.sp_inventory_student_sale('List', 32, 45, 62, p_student_id => 725, p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.item_name LIKE 'ZZ %' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n = 2, 'S11 the sales list shows both lines', v_n || ' lines');

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_m FROM _r;
    RAISE NOTICE '';
    RAISE NOTICE '== % passed, % failed ==', v_n, v_m;
END $t$;

ROLLBACK;
