-- ============================================================
-- BRONZE LAYER: Ingesta automatica de CSVs de transacciones POS de Taco Bueno
-- Archivo: src/transformations/silver/bronze_ingest.sql
-- ============================================================
--
-- PROPOSITO:
--   Lee todos los CSV del volumen /Volumes/workspace/default/tacobueno/data/
--   usando Auto Loader (read_files con STREAM) y los almacena en la tabla
--   bronze workspace.default.tb_daily_tld_bronze.
--
-- ESQUEMA:
--   Los CSV de 2025 tienen 19 columnas. Los de diciembre 2025 y 2026 anaden
--   Report Group y Tender Type (21 total). El esquema define 22 columnas
--   (incluye total_rounding para compatibilidad futura; ninguna columna
--   real lo tiene hoy). Las columnas faltantes se rellenan con NULL
--   automaticamente. El mapeo es posicional: la columna 1 del CSV
--   ("Store #") se asigna a store_number, la 2 ("Date") a txn_date, etc.
--
-- TRAZABILIDAD:
--   Conserva el nombre, ruta y fecha de modificacion del archivo de origen
--   y la marca de tiempo de ingesta.
--
-- AUTO LOADER:
--   El estado de los archivos procesados se gestiona mediante el checkpoint
--   del pipeline. No se reprocesan los archivos ya ingeridos. Los archivos
--   nuevos se incorporan automaticamente en la siguiente ejecucion.
--   Los archivos vacios no generan filas (no equivalen a cero ventas).
--   Un CSV repetido con otro nombre SI se procesa; se detecta en Silver
--   comparando source_file + contenido.
--
-- TIPOS:
--   Todas las columnas como STRING para evitar el problema de TIME(6)
--   en Delta Lake con compute serverless.
--
-- SALIDA: tabla workspace.default.tb_daily_tld_bronze
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
