-- ============================================================
-- SILVER LAYER: Cleaning and validation of Taco Bueno POS transactions
-- File: src/transformations/silver/silver_clean.sql
-- ============================================================
--
-- PURPOSE:
--   Reads the bronze table tb_daily_tld_bronze, standardizes data types,
--   cleans text, validates data, and produces the silver table
--   tb_daily_tld_silver.
--
-- IMPROVEMENTS OVER THE PREVIOUS CODE:
--   1. Preserves source_file for traceability and safe deduplication.
--   2. Uses DECIMAL(18,4) instead of DOUBLE for monetary columns
--      (avoids precision errors in sums and comparisons).
--   3. Uses TRY_CAST instead of CAST: invalid values -> NULL (no error).
--   4. Does not replace unknown amounts with 0 (total_discount, tax,
--      item_discount, item_voided, order_voided, total_rounding).
--      These remain NULL; missing values are not assumed to equal zero.
--   5. SELECT DISTINCT includes source_file: removes exact duplicates
--      within the same file while preserving identical rows that
--      appear in different files (allows Gold to detect duplicate CSVs
--      with different filenames).
--   6. Removes the valid_check_total >= 0 restriction: allows refunds
--      and voids with negative amounts.
--
-- GRANULARITY:
--   Each row = one item line within an order.
--   Order key = (store_number, txn_date, check_number).
--   check_total, total_discount, and tax repeat across all lines
--   of the same order; they must NOT be summed across item lines in Gold.
--
-- NULL HANDLING:
--   Text: "nan", "none", "null", "" -> NULL -> COALESCE to "desconocido"
--   ("unknown").
--   Numeric values: failed TRY_CAST -> NULL (preserved, not replaced with 0).
--   Columns missing in 2025 (report_group, tender_type, total_rounding)
--   -> NULL in bronze -> "desconocido" in silver for text columns.
--
-- OUTPUT: table workspace.default.tb_daily_tld_silver
-- ============================================================

-- SQL source for a Lakeflow pipeline in Databricks; configure the target catalog and schema.
-- Single-line explanatory comments; the original logic is preserved.
-- Depends on tb_daily_tld_bronze and contains the five original EXPECT expectations.

-- ============================================================================
-- SILVER: converts types, cleans text, applies five expectations, and removes identical projected rows.
-- Original file: src/transformations/silver/silver_clean.sql
-- ============================================================================

-- Stores the typed and normalized result. Its read does not use STREAM.
CREATE OR REFRESH MATERIALIZED VIEW tb_daily_tld_silver(
  -- EXPECT validates the output row. A null store causes the update to fail. It does not check whether the store exists in a business catalog.
  CONSTRAINT valid_store_number EXPECT (store_number IS NOT NULL) ON VIOLATION FAIL UPDATE,
  -- A null date causes the row to be dropped, provided the preceding conversion did not raise an error.
  CONSTRAINT valid_txn_date EXPECT (txn_date IS NOT NULL) ON VIOLATION DROP ROW,
  -- A null order number causes the row to be dropped; this does not enforce uniqueness.
  CONSTRAINT valid_check_number EXPECT (check_number IS NOT NULL) ON VIOLATION DROP ROW,
  -- Without ON VIOLATION, violations are recorded and invalid rows are RETAINED.
  CONSTRAINT valid_quantity EXPECT (quantity IS NOT NULL AND quantity >= 0),
  -- Invalid prices are also retained: this is a monitoring expectation.
  CONSTRAINT valid_menu_price EXPECT (menu_price IS NOT NULL AND menu_price >= 0)
)
COMMENT "Silver: cleaned and typed Taco Bueno POS transactions using DECIMAL. Includes source_file for traceability."
AS
-- Reading CTE. WITH assigns temporary names within this statement. SELECT * reads all columns, although typed will not retain all of them.
WITH bronze AS (
    SELECT * FROM tb_daily_tld_bronze
),
-- Conversion and cleansing CTE. Each expression keeps its output alias.
typed AS (
    SELECT
        -- Only the file name is propagated. Bronze paths and timestamps are not retained here.
        source_file,
        -- TRY_CAST: invalid or out-of-range text becomes NULL for these types. Integer conversion removes leading zeros from identifiers.
        TRY_CAST(store_number AS INT) AS store_number,
        -- Parses month/day/year. M is month, d is day, and yyyy is a four-digit year. NOTE: TO_DATE may fail on invalid dates; it is not TRY_CAST.
        TO_DATE(txn_date, "M/d/yyyy") AS txn_date,
        -- DECIMAL(18,4): 18 total digits, including four decimal places. Interpreted as the gross ORDER total repeated across lines.
        TRY_CAST(check_total AS DECIMAL(18,4)) AS check_total,
        -- BIGINT supports a wider range than INT. The key includes the store and date.
        TRY_CAST(check_number AS BIGINT) AS check_number,
        -- TRIM removes surrounding spaces; LOWER converts to lowercase; IN checks missing-value labels. CASE returns NULL or the cleaned text.
        CASE WHEN LOWER(TRIM(time_card)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(time_card)) END AS time_card,
        -- Times are copied as STRING; they are not validated and durations are not calculated.
        begin_time,
        end_time,
        -- Missing amounts and numeric flags remain NULL. They are not imputed as zero in Silver.
        TRY_CAST(total_discount AS DECIMAL(18,4)) AS total_discount,
        TRY_CAST(order_voided AS DECIMAL(18,4)) AS order_voided,
        TRY_CAST(tax AS DECIMAL(18,4)) AS tax,
        -- Integer quantity. Verify whether the POS supports fractional sales quantities.
        TRY_CAST(quantity AS INT) AS quantity,
        -- The same normalization applies to type, name, references, and channel. Gold filters use the normalized values.
        CASE WHEN LOWER(TRIM(transaction_type)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(transaction_type)) END AS transaction_type,
        CASE WHEN LOWER(TRIM(menu_item)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(menu_item)) END AS menu_item,
        CASE WHEN LOWER(TRIM(menu_item_ext_ref)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(menu_item_ext_ref)) END AS menu_item_ext_ref,
        CASE WHEN LOWER(TRIM(service_mode)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(service_mode)) END AS service_mode,
        CASE WHEN LOWER(TRIM(pos_code)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(pos_code)) END AS pos_code,
        -- Price is interpreted as a unit price; item_discount is interpreted per line. These business definitions require confirmation against the POS data contract.
        TRY_CAST(menu_price AS DECIMAL(18,4)) AS menu_price,
        TRY_CAST(item_discount AS DECIMAL(18,4)) AS item_discount,
        TRY_CAST(item_voided AS DECIMAL(18,4)) AS item_voided,
        -- Fields added to recent CSV files, according to the source description.
        CASE WHEN LOWER(TRIM(report_group)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(report_group)) END AS report_group,
        CASE WHEN LOWER(TRIM(tender_type)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(tender_type)) END AS tender_type,
        -- Field reserved for rounding; no current Gold formula uses it.
        TRY_CAST(total_rounding AS DECIMAL(18,4)) AS total_rounding
    FROM bronze
),
-- Missing-label CTE. COALESCE returns the first non-null value. Empty text has already become NULL; numeric values are not filled.
filled AS (
    SELECT
        -- Only the file name is propagated. Bronze paths and timestamps are not retained here.
        source_file,
        store_number,
        txn_date,
        check_total,
        check_number,
        -- Missing text is displayed as the existing label desconocido, meaning unknown; the actual value is not recovered.
        COALESCE(time_card, "desconocido") AS time_card,
        -- Times are copied as STRING; they are not validated and durations are not calculated.
        begin_time,
        end_time,
        total_discount,
        order_voided,
        tax,
        quantity,
        COALESCE(transaction_type, "desconocido") AS transaction_type,
        COALESCE(menu_item, "desconocido") AS menu_item,
        COALESCE(menu_item_ext_ref, "desconocido") AS menu_item_ext_ref,
        COALESCE(service_mode, "desconocido") AS service_mode,
        COALESCE(pos_code, "desconocido") AS pos_code,
        menu_price,
        item_discount,
        item_voided,
        COALESCE(report_group, "desconocido") AS report_group,
        COALESCE(tender_type, "desconocido") AS tender_type,
        total_rounding
    FROM typed
)
-- DISTINCT compares ALL projected columns after cleansing. With a different source_file, an otherwise identical row remains distinct. NOTE: this can remove two legitimate identical order lines. It also does not detect renamed file copies or preserve their paths.
SELECT DISTINCT
    source_file,
    store_number, txn_date, check_total, check_number, time_card,
    begin_time, end_time, total_discount, order_voided, tax, quantity,
    transaction_type, menu_item, menu_item_ext_ref, service_mode,
    pos_code, menu_price, item_discount, item_voided,
    report_group, tender_type, total_rounding
FROM filled;

