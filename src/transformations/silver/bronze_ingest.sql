-- ============================================================
-- BRONZE LAYER: Automatic ingestion of Taco Bueno POS transaction CSVs
-- File: src/transformations/silver/bronze_ingest.sql
-- ============================================================
--
-- PURPOSE:
--   Reads all CSVs from the /Volumes/workspace/default/tacobueno/data/
--   volume using Auto Loader (read_files with STREAM) and stores them
--   in the bronze table workspace.default.tb_daily_tld_bronze.
--
-- SCHEMA:
--   The 2025 CSVs have 19 columns. Those from December 2025 and 2026 add
--   Report Group and Tender Type (21 total). The schema defines 22 columns
--   (including total_rounding for future compatibility; no actual file
--   currently contains it). Missing columns are automatically filled
--   with NULL. Mapping is positional: CSV column 1 ("Store #") maps to
--   store_number, column 2 ("Date") maps to txn_date, etc.
--
-- TRACEABILITY:
--   Preserves the source file's name, path, and modification date,
--   along with the ingestion timestamp.
--
-- AUTO LOADER:
--   The status of processed files is managed through the pipeline
--   checkpoint. Previously ingested files are not reprocessed. New files
--   are automatically included in the next run.
--   Empty files produce no rows (they do not represent zero sales).
--   A duplicate CSV with a different filename IS processed; it is detected
--   in Silver by comparing source_file + content.
--
-- DATA TYPES:
--   All columns use STRING to avoid the TIME(6) issue
--   in Delta Lake with serverless compute.
--
-- OUTPUT: table workspace.default.tb_daily_tld_bronze
-- ============================================================

CREATE OR REFRESH STREAMING TABLE tb_daily_tld_bronze
COMMENT "Bronze: transacciones POS Taco Bueno desde CSV via Auto Loader. Todas las columnas como STRING. Incluye trazabilidad de archivo origen."
AS SELECT
    _metadata.file_name             AS source_file,
    _metadata.file_path             AS source_file_path,
    _metadata.file_modification_time AS source_file_mtime,
    current_timestamp()             AS ingestion_timestamp,
    store_number, txn_date, check_total, check_number, time_card,
    begin_time, end_time, total_discount, order_voided, tax, quantity,
    transaction_type, menu_item, menu_item_ext_ref, service_mode,
    pos_code, menu_price, item_discount, item_voided,
    report_group, tender_type, total_rounding
FROM STREAM read_files(
    "/Volumes/workspace/default/tacobueno/data",
    format => "csv",
    header => true,
    inferSchema => false,
    schema => "store_number STRING, txn_date STRING, check_total STRING, check_number STRING, time_card STRING, begin_time STRING, end_time STRING, total_discount STRING, order_voided STRING, tax STRING, quantity STRING, transaction_type STRING, menu_item STRING, menu_item_ext_ref STRING, service_mode STRING, pos_code STRING, menu_price STRING, item_discount STRING, item_voided STRING, report_group STRING, tender_type STRING, total_rounding STRING"
);
