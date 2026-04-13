-- 0) Optional: drop old tables
DROP TABLE IF EXISTS sales_clean_base;
DROP TABLE IF EXISTS sales_dirty;

-- 1) Clean base table (foundation)
CREATE TABLE sales_clean_base (
    sale_id BIGSERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    product_id INT NOT NULL,
    sale_ts TIMESTAMPTZ NOT NULL,
    quantity INT NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    channel TEXT NOT NULL,
    currency TEXT NOT NULL,
    notes TEXT
);

-- Tune this for scale
-- 1,000,000 rows typical; go larger if you want.
DO $$
DECLARE
    N_BASE BIGINT := 1000000;
BEGIN
    INSERT INTO sales_clean_base (customer_id, product_id, sale_ts, quantity, amount, channel, currency, notes)
    SELECT
        -- realistic: customers 1..200k, but with "hot" customers boosted
        CASE
            WHEN random() < 0.05 THEN (1 + floor(random()*5000))::int -- a few very frequent customers
            ELSE (1 + floor(random()*200000))::int
        END AS customer_id,
        
        -- realistic: products 1..20k, but with "hot" products boosted
        CASE
            WHEN random() < 0.10 THEN (1 + floor(random()*200))::int -- popular products
            ELSE (1 + floor(random()*20000))::int
        END AS product_id,
        
        -- timestamps: last 365 days with slight weekend/time-of-day structure
        (now() - (floor(random()*365))::int * interval '1 day' + (floor(random()*24))::int * interval '1 hour' + (floor(random()*60))::int * interval '1 minute') AS sale_ts,
        
        -- quantity: mostly small, occasional larger
        CASE
            WHEN random() < 0.90 THEN (1 + floor(random()*4))::int -- 1..4
            WHEN random() < 0.99 THEN (5 + floor(random()*10))::int -- 5..14
            ELSE (20 + floor(random()*200))::int -- rare big orders
        END AS quantity,
        
        -- amount: correlated with quantity and product price
        ROUND(
            (10 + random()*200) * (CASE WHEN random() < 0.90 THEN 1 ELSE (1 + random()*3) END) * 
            (CASE WHEN random() < 0.85 THEN 1 ELSE (0.2 + random()*0.8) END) *
            (CASE WHEN random() < 0.98 THEN 1 ELSE (10 + random()*50) END)
        ) AS amount,
        
        -- channel: common values
        (ARRAY['online','store','partner','mobile_app'])[1 + floor(random()*4)] AS channel,
        (ARRAY['USD','EUR','GBP','PKR'])[1 + floor(random()*4)] AS currency,
        NULL::text AS notes
    FROM generate_series(1, N_BASE);
END $$;

-- 2) Dirty / contaminated table (intentionally messy)
CREATE TABLE sales_dirty (
    sale_id BIGINT,
    customer_id INT,
    product_id INT,
    sale_ts TIMESTAMPTZ,
    quantity INT,
    amount NUMERIC(12,2),
    channel TEXT,
    currency_raw TEXT, -- intentionally "raw" dirty currency values
    notes TEXT
);

-- 3) Start by copying the clean base (as the majority of data)
INSERT INTO sales_dirty (sale_id, customer_id, product_id, sale_ts, quantity, amount, channel, currency_raw, notes)
SELECT sale_id, customer_id, product_id, sale_ts, quantity, amount, channel, currency, notes
FROM sales_clean_base;

-- 4) Inject exact duplicates (e.g., 2% of base)
INSERT INTO sales_dirty
SELECT * FROM sales_clean_base
WHERE random() < 0.02;

-- 5) Inject near-duplicates (same sale_id/customer/product/time, tiny drift)
INSERT INTO sales_dirty (sale_id, customer_id, product_id, sale_ts, quantity, amount, channel, currency_raw, notes)
SELECT sale_id, customer_id, product_id, sale_ts + (CASE WHEN random() < 0.5 THEN interval '0' ELSE interval '5 seconds' END),
       CASE WHEN random() < 0.8 THEN quantity ELSE quantity + 1 END,
       CASE WHEN random() < 0.7 THEN amount ELSE ROUND(amount + (random()*2 - 1)::numeric, 2) END,
       CASE WHEN random() < 0.33 THEN upper(channel) ELSE channel END,
       currency,
       'near-duplicate variant'
FROM sales_clean_base
WHERE random() < 0.02;

-- 6) Inject missing values (NULLs) and placeholder tokens
UPDATE sales_dirty
SET
    customer_id = CASE WHEN random() < 0.25 THEN NULL ELSE customer_id END,
    product_id = CASE WHEN random() < 0.20 THEN NULL ELSE product_id END,
    sale_ts = CASE WHEN random() < 0.10 THEN NULL ELSE sale_ts END,
    channel = CASE WHEN random() < 0.15 THEN NULL ELSE channel END,
    notes = CASE WHEN random() < 0.30 THEN 'missing fields injected' ELSE notes END
WHERE random() < 0.05;

-- 7) Inject invalid ranges + outliers (e.g., 3%)
UPDATE sales_dirty
SET
    quantity = CASE
        WHEN random() < 0.25 THEN -1 * (1 + floor(random()*5))::int -- negative qty
        WHEN random() < 0.50 THEN 0 -- zero qty
        WHEN random() < 0.75 THEN (1000 + floor(random()*5000))::int -- extreme qty
        ELSE quantity
    END,
    amount = CASE
        WHEN random() < 0.25 THEN -1 * ROUND((random()*500)::numeric, 2) -- negative amount
        WHEN random() < 0.50 THEN 0::numeric(12,2) -- zero amount
        WHEN random() < 0.75 THEN ROUND((100000 + random()*900000)::numeric, 2) -- extreme amount
        ELSE amount
    END,
    notes = COALESCE(notes, '') || ' | invalid-range/outlier injected'
WHERE random() < 0.03;

-- 8) Inject timestamp anomalies (future + very old) (e.g., 2%)
UPDATE sales_dirty
SET
    sale_ts = CASE
        WHEN random() < 0.50 THEN now() + (1 + floor(random()*30))::int * interval '1 day' -- future
        ELSE now() - (3650 + floor(random()*3650))::int * interval '1 day' -- 10-20y old
    END,
    notes = COALESCE(notes, '') || ' | timestamp anomaly'
WHERE random() < 0.02;

-- 9) Inject referential issues: ids outside expected ranges (e.g., 2%)
UPDATE sales_dirty
SET
    customer_id = CASE WHEN random() < 0.5 THEN (300000 + floor(random()*500000))::int ELSE customer_id END,
    product_id = CASE WHEN random() < 0.5 THEN (50000 + floor(random()*200000))::int ELSE product_id END,
    notes = COALESCE(notes, '') || ' | orphan ids'
WHERE random() < 0.02;

-- 10) Inject currency formatting/type issues into currency_raw (e.g., 4%)
UPDATE sales_dirty
SET
    currency_raw = CASE
        WHEN random() < 0.25 THEN '$' || amount::text -- symbol prefix
        WHEN random() < 0.50 THEN amount::text || ' ' || currency_raw -- suffix currency
        WHEN random() < 0.75 THEN replace(amount::text, '.', ',') -- comma decimal
        ELSE currency_raw
    END,
    notes = COALESCE(notes, '') || ' | currency format issue'
WHERE random() < 0.04;

-- Done.
-- sales_clean_base: mostly clean
-- sales_dirty: large dataset with realistic contamination