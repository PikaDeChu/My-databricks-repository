-- ============================================================
-- SILVER LAYER: Limpieza y validacion de transacciones POS de Taco Bueno
-- Archivo: src/transformations/silver/silver_clean.sql
-- ============================================================
--
-- PROPOSITO:
--   Lee la tabla bronze tb_daily_tld_bronze, normaliza tipos, limpia textos,
--   valida datos y produce la tabla silver tb_daily_tld_silver.
--
-- MEJORAS RESPECTO AL CODIGO ANTERIOR:
--   1. Conserva source_file para trazabilidad y deduplicacion segura.
--   2. Usa DECIMAL(18,4) en vez de DOUBLE para columnas monetarias
--      (evita errores de precision en sumas y comparaciones).
--   3. Usa TRY_CAST en vez de CAST: valores invalidos -> NULL (no error).
--   4. No rellena con 0 los importes desconocidos (total_discount, tax,
--      item_discount, item_voided, order_voided, total_rounding).
--      Se dejan como NULL; no se asume que un valor ausente equivalga a cero.
--   5. SELECT DISTINCT incluye source_file: elimina duplicados exactos
--      dentro del mismo archivo, pero conserva filas identicas que
--      aparecen en archivos diferentes (permite detectar CSVs repetidos
--      con otro nombre en Gold).
--   6. Quita la restriccion valid_check_total >= 0: permite devoluciones
--      y anulaciones con importe negativo.
--
-- GRANULARIDAD:
--   Cada fila = una linea de articulo dentro de una orden.
--   Clave de orden = (store_number, txn_date, check_number).
--   check_total, total_discount y tax se repiten en todas las lineas
--   de la misma orden; NO se deben sumar por linea en Gold.
--
-- TRATAMIENTO DE NULOS:
--   Textos: "nan", "none", "null", "" -> NULL -> COALESCE a "desconocido".
--   Numericos: TRY_CAST fallido -> NULL (se conserva, no se convierte a 0).
--   Columnas ausentes en 2025 (report_group, tender_type, total_rounding)
--   -> NULL en bronze -> "desconocido" en silver para textos.
--
-- SALIDA: tabla workspace.default.tb_daily_tld_silver
-- ============================================================

CREATE OR REFRESH MATERIALIZED VIEW tb_daily_tld_silver(
  CONSTRAINT valid_store_number EXPECT (store_number IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT valid_txn_date EXPECT (txn_date IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_check_number EXPECT (check_number IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_quantity EXPECT (quantity IS NOT NULL AND quantity >= 0),
  CONSTRAINT valid_menu_price EXPECT (menu_price IS NOT NULL AND menu_price >= 0)
)
COMMENT "Silver: transacciones POS Taco Bueno limpias y tipadas con DECIMAL. Incluye source_file para trazabilidad."
AS
WITH bronze AS (
    SELECT * FROM tb_daily_tld_bronze
),
typed AS (
    SELECT
        source_file,
        TRY_CAST(store_number AS INT) AS store_number,
        TO_DATE(txn_date, "M/d/yyyy") AS txn_date,
        TRY_CAST(check_total AS DECIMAL(18,4)) AS check_total,
        TRY_CAST(check_number AS BIGINT) AS check_number,
        CASE WHEN LOWER(TRIM(time_card)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(time_card)) END AS time_card,
        begin_time,
        end_time,
        TRY_CAST(total_discount AS DECIMAL(18,4)) AS total_discount,
        TRY_CAST(order_voided AS DECIMAL(18,4)) AS order_voided,
        TRY_CAST(tax AS DECIMAL(18,4)) AS tax,
        TRY_CAST(quantity AS INT) AS quantity,
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
        TRY_CAST(menu_price AS DECIMAL(18,4)) AS menu_price,
        TRY_CAST(item_discount AS DECIMAL(18,4)) AS item_discount,
        TRY_CAST(item_voided AS DECIMAL(18,4)) AS item_voided,
        CASE WHEN LOWER(TRIM(report_group)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(report_group)) END AS report_group,
        CASE WHEN LOWER(TRIM(tender_type)) IN ("nan", "none", "null", "") THEN NULL
             ELSE LOWER(TRIM(tender_type)) END AS tender_type,
        TRY_CAST(total_rounding AS DECIMAL(18,4)) AS total_rounding
    FROM bronze
),
filled AS (
    SELECT
        source_file,
        store_number,
        txn_date,
        check_total,
        check_number,
        COALESCE(time_card, "desconocido") AS time_card,
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
-- Deduplicacion: DISTINCT incluyendo source_file.
-- Elimina duplicados exactos dentro del mismo archivo CSV.
-- Conserva filas identicas que aparecen en archivos diferentes
-- (un CSV repetido con otro nombre se detecta en Gold por source_file).
SELECT DISTINCT
    source_file,
    store_number, txn_date, check_total, check_number, time_card,
    begin_time, end_time, total_discount, order_voided, tax, quantity,
    transaction_type, menu_item, menu_item_ext_ref, service_mode,
    pos_code, menu_price, item_discount, item_voided,
    report_group, tender_type, total_rounding
FROM filled;
