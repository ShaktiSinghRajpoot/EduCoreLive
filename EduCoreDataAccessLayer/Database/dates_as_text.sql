-- ============================================================================
-- Store dates as text (ISO YYYY-MM-DD) instead of the date type.
--
-- Requested change. Recorded here so the next reader knows what it costs:
-- PostgreSQL no longer refuses '2026-13-45', and every place that does date
-- arithmetic now has to cast back with ::date. ISO text does sort correctly,
-- so ORDER BY and the end_date > start_date style checks still hold.
--
-- The format is fixed at YYYY-MM-DD everywhere. Anything that writes one of
-- these columns must write that shape, or the ::date casts downstream will
-- throw at read time rather than at write time.
--
-- Target DB: PostgreSQL. Safe to re-run (each ALTER is guarded).
-- ============================================================================

-- The one view over these columns has to go first and come back after.
DROP VIEW IF EXISTS core.v_fee_tender_lines;

-- The three range checks compare two date columns, so they cannot survive the
-- moment when one has been converted and the other has not. Dropped here and
-- re-added at the end — on ISO text they mean exactly the same thing, because
-- YYYY-MM-DD sorts in date order.
ALTER TABLE academic.academic_years DROP CONSTRAINT IF EXISTS chk_academic_year_dates;
ALTER TABLE academic.exams          DROP CONSTRAINT IF EXISTS chk_exams_dates;
ALTER TABLE core.staff_leave        DROP CONSTRAINT IF EXISTS chk_staff_leave_dates;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='academic_years'
                 AND column_name='end_date' AND data_type='date') THEN
        ALTER TABLE academic.academic_years ALTER COLUMN end_date TYPE varchar(10)
            USING to_char(end_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='academic_years'
                 AND column_name='start_date' AND data_type='date') THEN
        ALTER TABLE academic.academic_years ALTER COLUMN start_date TYPE varchar(10)
            USING to_char(start_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exam_subjects'
                 AND column_name='exam_date' AND data_type='date') THEN
        ALTER TABLE academic.exam_subjects ALTER COLUMN exam_date TYPE varchar(10)
            USING to_char(exam_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exams'
                 AND column_name='end_date' AND data_type='date') THEN
        ALTER TABLE academic.exams ALTER COLUMN end_date TYPE varchar(10)
            USING to_char(end_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exams'
                 AND column_name='start_date' AND data_type='date') THEN
        ALTER TABLE academic.exams ALTER COLUMN start_date TYPE varchar(10)
            USING to_char(start_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='school_calendar'
                 AND column_name='calendar_date' AND data_type='date') THEN
        ALTER TABLE academic.school_calendar ALTER COLUMN calendar_date TYPE varchar(10)
            USING to_char(calendar_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='enquiries'
                 AND column_name='dob' AND data_type='date') THEN
        ALTER TABLE core.enquiries ALTER COLUMN dob TYPE varchar(10)
            USING to_char(dob, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='enquiries'
                 AND column_name='enquiry_date' AND data_type='date') THEN
        ALTER TABLE core.enquiries ALTER COLUMN enquiry_date DROP DEFAULT;
        ALTER TABLE core.enquiries ALTER COLUMN enquiry_date TYPE varchar(10)
            USING to_char(enquiry_date, 'YYYY-MM-DD');
        ALTER TABLE core.enquiries ALTER COLUMN enquiry_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='enquiries'
                 AND column_name='next_followup_date' AND data_type='date') THEN
        ALTER TABLE core.enquiries ALTER COLUMN next_followup_date TYPE varchar(10)
            USING to_char(next_followup_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='enquiries'
                 AND column_name='registration_date' AND data_type='date') THEN
        ALTER TABLE core.enquiries ALTER COLUMN registration_date TYPE varchar(10)
            USING to_char(registration_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='enquiry_followups'
                 AND column_name='next_followup_date' AND data_type='date') THEN
        ALTER TABLE core.enquiry_followups ALTER COLUMN next_followup_date TYPE varchar(10)
            USING to_char(next_followup_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='fee_day_close'
                 AND column_name='close_date' AND data_type='date') THEN
        ALTER TABLE core.fee_day_close ALTER COLUMN close_date TYPE varchar(10)
            USING to_char(close_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='fee_payments'
                 AND column_name='payment_date' AND data_type='date') THEN
        ALTER TABLE core.fee_payments ALTER COLUMN payment_date DROP DEFAULT;
        ALTER TABLE core.fee_payments ALTER COLUMN payment_date TYPE varchar(10)
            USING to_char(payment_date, 'YYYY-MM-DD');
        ALTER TABLE core.fee_payments ALTER COLUMN payment_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='inventory_purchases'
                 AND column_name='purchase_date' AND data_type='date') THEN
        ALTER TABLE core.inventory_purchases ALTER COLUMN purchase_date TYPE varchar(10)
            USING to_char(purchase_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='inventory_stock_ledger'
                 AND column_name='movement_date' AND data_type='date') THEN
        ALTER TABLE core.inventory_stock_ledger ALTER COLUMN movement_date DROP DEFAULT;
        ALTER TABLE core.inventory_stock_ledger ALTER COLUMN movement_date TYPE varchar(10)
            USING to_char(movement_date, 'YYYY-MM-DD');
        ALTER TABLE core.inventory_stock_ledger ALTER COLUMN movement_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='staff'
                 AND column_name='dob' AND data_type='date') THEN
        ALTER TABLE core.staff ALTER COLUMN dob TYPE varchar(10)
            USING to_char(dob, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='staff'
                 AND column_name='joining_date' AND data_type='date') THEN
        ALTER TABLE core.staff ALTER COLUMN joining_date TYPE varchar(10)
            USING to_char(joining_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='staff_leave'
                 AND column_name='from_date' AND data_type='date') THEN
        ALTER TABLE core.staff_leave ALTER COLUMN from_date TYPE varchar(10)
            USING to_char(from_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='staff_leave'
                 AND column_name='to_date' AND data_type='date') THEN
        ALTER TABLE core.staff_leave ALTER COLUMN to_date TYPE varchar(10)
            USING to_char(to_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='student_attendance'
                 AND column_name='attendance_date' AND data_type='date') THEN
        ALTER TABLE core.student_attendance ALTER COLUMN attendance_date TYPE varchar(10)
            USING to_char(attendance_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='student_ledger'
                 AND column_name='due_date' AND data_type='date') THEN
        ALTER TABLE core.student_ledger ALTER COLUMN due_date TYPE varchar(10)
            USING to_char(due_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='student_transport'
                 AND column_name='start_date' AND data_type='date') THEN
        ALTER TABLE core.student_transport ALTER COLUMN start_date DROP DEFAULT;
        ALTER TABLE core.student_transport ALTER COLUMN start_date TYPE varchar(10)
            USING to_char(start_date, 'YYYY-MM-DD');
        ALTER TABLE core.student_transport ALTER COLUMN start_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='students'
                 AND column_name='admission_date' AND data_type='date') THEN
        ALTER TABLE core.students ALTER COLUMN admission_date DROP DEFAULT;
        ALTER TABLE core.students ALTER COLUMN admission_date TYPE varchar(10)
            USING to_char(admission_date, 'YYYY-MM-DD');
        ALTER TABLE core.students ALTER COLUMN admission_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='students'
                 AND column_name='date_of_leaving' AND data_type='date') THEN
        ALTER TABLE core.students ALTER COLUMN date_of_leaving TYPE varchar(10)
            USING to_char(date_of_leaving, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='students'
                 AND column_name='dob' AND data_type='date') THEN
        ALTER TABLE core.students ALTER COLUMN dob TYPE varchar(10)
            USING to_char(dob, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='tc_register'
                 AND column_name='admission_date' AND data_type='date') THEN
        ALTER TABLE core.tc_register ALTER COLUMN admission_date TYPE varchar(10)
            USING to_char(admission_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='tc_register'
                 AND column_name='application_date' AND data_type='date') THEN
        ALTER TABLE core.tc_register ALTER COLUMN application_date TYPE varchar(10)
            USING to_char(application_date, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='tc_register'
                 AND column_name='date_of_leaving' AND data_type='date') THEN
        ALTER TABLE core.tc_register ALTER COLUMN date_of_leaving TYPE varchar(10)
            USING to_char(date_of_leaving, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='tc_register'
                 AND column_name='dob' AND data_type='date') THEN
        ALTER TABLE core.tc_register ALTER COLUMN dob TYPE varchar(10)
            USING to_char(dob, 'YYYY-MM-DD');
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='core' AND table_name='tc_register'
                 AND column_name='issue_date' AND data_type='date') THEN
        ALTER TABLE core.tc_register ALTER COLUMN issue_date DROP DEFAULT;
        ALTER TABLE core.tc_register ALTER COLUMN issue_date TYPE varchar(10)
            USING to_char(issue_date, 'YYYY-MM-DD');
        ALTER TABLE core.tc_register ALTER COLUMN issue_date SET DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;
END $$;

-- Back with the same shape the app already reads.
CREATE OR REPLACE VIEW core.v_fee_tender_lines AS
SELECT p.payment_id,
       p.tenant_id,
       p.school_id,
       p.created_by,
       p.payment_date,
       p.is_cancelled,
       COALESCE(t.mode, p.payment_mode) AS mode,
       COALESCE(t.amount, p.amount) AS amount
FROM core.fee_payments p
LEFT JOIN core.fee_payment_tenders t ON t.payment_id = p.payment_id;

-- Same meaning, now on text.
ALTER TABLE academic.academic_years
    ADD CONSTRAINT chk_academic_year_dates CHECK (end_date > start_date);
ALTER TABLE academic.exams
    ADD CONSTRAINT chk_exams_dates CHECK (end_date >= start_date);
ALTER TABLE core.staff_leave
    ADD CONSTRAINT chk_staff_leave_dates CHECK (to_date >= from_date);
