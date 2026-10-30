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

-- SQL source for a Lakeflow pipeline in Databricks; configure the target catalog and schema.
-- Single-line explanatory comments; the original logic is preserved.
-- Reads CSV files from the volume; contains no EXPECT expectations.

-- ============================================================================
-- BRONZE: reads new CSV files, preserves data as text, and records its provenance.
-- Original file: src/transformations/silver/bronze_ingest.sql
-- ============================================================================

-- Declares the managed ingestion table. The checkpoint preserves progress. Update scheduling is configured outside this SQL.
CREATE OR REFRESH STREAMING TABLE tb_daily_tld_bronze
-- COMMENT stores a description as metadata. It does not validate the content.
COMMENT "Bronze: Taco Bueno POS transactions from CSV files through Auto Loader. CSV fields are STRING. Includes source file traceability."
-- SELECT defines the output columns; AS assigns aliases to expressions.
AS SELECT
    -- File name. The same name may appear in different folders.
    _metadata.file_name             AS source_file,
    -- Full file path; provides a more precise identity than the file name.
    _metadata.file_path             AS source_file_path,
    -- File modification time, not the sale date.
    _metadata.file_modification_time AS source_file_mtime,
    -- Time at which ingestion is evaluated. It is not a unique row ID.
    current_timestamp()             AS ingestion_timestamp,
    -- Projects the 22 CSV fields as STRING without business cleansing. Together with four provenance columns, Bronze exposes 26 columns. Temporal metadata uses TIMESTAMP; not every column is STRING.
    store_number, txn_date, check_total, check_number, time_card,
    begin_time, end_time, total_discount, order_voided, tax, quantity,
    transaction_type, menu_item, menu_item_ext_ref, service_mode,
    pos_code, menu_price, item_discount, item_voided,
    report_group, tender_type, total_rounding
-- read_files returns records from files; STREAM integrates Auto Loader. File tracking does not remove copies of the same content at another path.
FROM STREAM read_files(
    -- Volume path: workspace catalog, default schema, tacobueno volume. data is a folder in the volume; it does not set the target schema for tables.
    "/Volumes/workspace/default/tacobueno/data",
    -- Named argument using =>. Selects the CSV reader.
    format => "csv",
    -- Indicates that files contain a header row. NOTE: this does not guarantee positional renaming from Store # to store_number. Validate actual header alignment and rescued data behavior.
    header => true,
    -- Expresses the intent not to infer types. The explicit schema already sets them. NOTE: read_files documents inferColumnTypes for this purpose. Do not rely on inferSchema as the main Auto Loader control.
    inferSchema => false,
    -- Explicit schema: 19 base fields, report_group, tender_type, and total_rounding. Missing columns and header changes require reader tests. NOTE: no rescued data column such as _rescued_data is projected.
    schema => "store_number STRING, txn_date STRING, check_total STRING, check_number STRING, time_card STRING, begin_time STRING, end_time STRING, total_discount STRING, order_voided STRING, tax STRING, quantity STRING, transaction_type STRING, menu_item STRING, menu_item_ext_ref STRING, service_mode STRING, pos_code STRING, menu_price STRING, item_discount STRING, item_voided STRING, report_group STRING, tender_type STRING, total_rounding STRING"
);
