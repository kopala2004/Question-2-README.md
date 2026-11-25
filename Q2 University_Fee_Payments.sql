-- (a) Database and seed data
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL,
    fee_due NUMERIC(12, 2) NOT NULL,
    CONSTRAINT chk_students_fee_due_nonneg CHECK (fee_due >= 0.00)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    paid_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_payments_student FOREIGN KEY (student_id)
        REFERENCES students(student_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_payments_amount_pos CHECK (amount > 0.00)
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL,
    student_id INT NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_payment FOREIGN KEY (payment_id)
        REFERENCES payments(payment_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_audit_student FOREIGN KEY (student_id)
        REFERENCES students(student_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_audit_amount_pos CHECK (amount > 0.00)
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    CONSTRAINT chk_daily_cnt_nonneg CHECK (payment_count >= 0),
    CONSTRAINT chk_daily_amt_nonneg CHECK (total_amount >= 0.00)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU2026001', 'Amina Banda', 4500.00),
    ('STU2026002', 'Chanda Mwape', 2200.00),
    ('STU2026003', 'Mutale Phiri', 5800.00);

INSERT INTO payments (student_id, amount, paid_on) VALUES
    (1, 1000.00, '2026-11-20 09:15:00'),
    (1, 1200.00, '2026-11-21 11:30:00'),
    (1, 800.00,  '2026-11-22 14:10:00'),
    (2, 700.00,  '2026-11-22 15:45:00'),
    (2, 900.00,  '2026-11-23 10:05:00'),
    (2, 600.00,  '2026-11-24 13:20:00');



-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_total_paid NUMERIC(12, 2);
BEGIN
    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: student_id % does not exist.', p_student_id
            USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_total_paid
      FROM payments
     WHERE student_id = p_student_id;

    RETURN GREATEST(v_fee_due - v_total_paid, 0.00);
END;
$$;



-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    IN p_student_id INT,
    IN p_amount NUMERIC(12, 2),
    IN p_paid_on TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_total_paid NUMERIC(12, 2);
    v_balance NUMERIC(12, 2);
    v_effective_paid_on TIMESTAMP;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0.00 THEN
        RAISE EXCEPTION 'Invalid amount: payment amount must be greater than zero.'
            USING ERRCODE = 'P0001';
    END IF;

    v_effective_paid_on := COALESCE(p_paid_on, CURRENT_TIMESTAMP);

    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: student_id % does not exist.', p_student_id
            USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_total_paid
      FROM payments
     WHERE student_id = p_student_id;

    v_balance := GREATEST(v_fee_due - v_total_paid, 0.00);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected: amount exceeds outstanding balance.'
            USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, v_effective_paid_on);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_payments_after_insert_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_after_insert_audit ON payments;

CREATE TRIGGER trg_payments_after_insert_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_after_insert_audit();

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    (s.fee_due - COALESCE(p.total_paid, 0.00)) AS outstanding_balance
FROM students s
LEFT JOIN (
    SELECT
        student_id,
        SUM(amount) AS total_paid
    FROM payments
    GROUP BY student_id
) p ON p.student_id = s.student_id
WHERE (s.fee_due - COALESCE(p.total_paid, 0.00)) > 0.00;

-- (f) Index
CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);

SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
  AND paid_on >= '2026-11-20 00:00:00'::timestamp
  AND paid_on <  '2026-11-23 00:00:00'::timestamp
ORDER BY paid_on;

EXPLAIN
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
  AND paid_on >= '2026-11-20 00:00:00'::timestamp
  AND paid_on <  '2026-11-23 00:00:00'::timestamp
ORDER BY paid_on;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    IN p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE;
    v_payment_count INT;
    v_total_amount NUMERIC(12, 2);
BEGIN
    v_target_day := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::date);

    SELECT
        COUNT(*),
        COALESCE(SUM(amount), 0.00)
      INTO
        v_payment_count,
        v_total_amount
      FROM payments
     WHERE paid_on >= (v_target_day::timestamp)
       AND paid_on <  ((v_target_day + INTERVAL '1 day')::timestamp);

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (v_target_day, v_payment_count, v_total_amount)
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'evt_refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
