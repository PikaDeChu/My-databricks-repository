-- ============================================================
-- GOLD LAYER: Metricas de ventas de Taco Bueno
-- Archivo: src/transformations/gold/gold_metrics.sql
-- ============================================================
--
-- PROPOSITO:
--   Calcula las metricas comerciales de Taco Bueno a partir de Silver.
--   Tablas creadas (todas en workspace.default):
--
--   1. tb_gold_orders            -- Una fila por orden unica
--   2. tb_gold_sales_daily       -- Ventas diarias por sucursal
--   3. tb_gold_products          -- Metricas por producto (unidades, precio promedio, moda)
--   4. tb_gold_products_by_store -- Metricas por producto y sucursal
--   5. tb_gold_discounts         -- Analisis de descuentos (con vs sin)
--   6. tb_gold_discount_products -- Productos que reciben descuento
--
-- DEFINICIONES CLAVE (verificadas contra los datos reales):
--   * Clave de orden = (store_number, txn_date, check_number).
--     check_number NO es unico entre fechas; se repite entre dias.
--   * check_total = Total de la orden (bruto antes de descuento).
--     Se repite en cada linea de la orden; NO se suma por linea.
--   * total_discount = Descuento total de la orden (repetido por linea).
--   * menu_price = Precio UNITARIO del articulo (no importe por linea).
--     Importe bruto de linea = menu_price * quantity.
--   * tax = Impuesto de la orden (repetido por linea).
--     El impuesto se calcula sobre el neto (total - descuento).
--   * Ventas brutas = check_total (una vez por orden).
--   * Ventas netas = check_total - total_discount.
--   * Ticket promedio = promedio de ventas netas por orden.
--   * No existen costos de productos; no se calculan ganancias.
--
-- TRATAMIENTO DE ANULACIONES:
--   * transaction_type = 'void' -> linea anulada.
--   * item_voided > 0 -> articulo anulado.
--   * order_voided > 0 -> orden anulada.
--   * Las ordenes completamente anuladas se excluyen de las metricas
--     de ventas, pero se conservan en tb_gold_orders con is_voided = TRUE.
--
-- TRATAMIENTO DE ARTICULOS:
--   * Para metricas de producto, solo se incluyen lineas activas:
--     transaction_type IN ('regular sale', 'discount') AND
--     item_voided = 0 (o NULL) AND quantity > 0 AND menu_price > 0.
--   * Los componentes de combo (menu_price = 0) y modificadores
--     (quantity = 0) no se cuentan como unidades vendidas.
--
-- COMPARACIONES CON/SIN DESCUENTO:
--   * Es descriptiva: no implica causalidad. Una diferencia en ticket
--     promedio puede deberse al tipo de producto, la sucursal o el dia,
--     no solo al descuento.
-- ============================================================


-- ============================================================
-- 1. tb_gold_orders: resumen a nivel orden
-- Una fila por (store_number, txn_date, check_number).
-- check_total, total_discount y tax se toman una sola vez (MAX)
-- porque estan repetidos en cada linea de la orden en Silver.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_orders
COMMENT "Gold: resumen por orden. Clave = (store_number, txn_date, check_number). check_total no se suma por linea."
AS
WITH order_agg AS (
    SELECT
        store_number,
        txn_date,
        check_number,
        MAX(check_total)                                  AS gross_sales,
        MAX(total_discount)                               AS total_discount,
        MAX(tax)                                          AS tax,
        COUNT(*)                                          AS line_count,
        COUNT(DISTINCT check_total)                       AS distinct_totals,
        SUM(CASE WHEN transaction_type = 'void' THEN 1 ELSE 0 END) AS void_lines,
        MIN(CASE WHEN transaction_type != 'void' THEN 1 ELSE 0 END) AS has_non_void_line,
        MAX(CASE WHEN order_voided > 0 THEN 1 ELSE 0 END)  AS has_order_void,
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  AND quantity > 0
                 THEN menu_price * quantity ELSE 0 END)   AS line_gross_sum,
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  AND quantity > 0
                 THEN COALESCE(item_discount, 0) ELSE 0 END) AS line_discount_sum,
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  AND quantity > 0 AND menu_price > 0
                 THEN 1 ELSE 0 END)                        AS active_line_count,
        COLLECT_SET(service_mode)                         AS service_modes
    FROM tb_daily_tld_silver
    WHERE store_number IS NOT NULL
      AND txn_date IS NOT NULL
      AND check_number IS NOT NULL
    GROUP BY store_number, txn_date, check_number
)
SELECT
    store_number,
    txn_date,
    check_number,
    gross_sales,
    total_discount,
    tax,
    -- Ventas netas = bruto - descuento.
    -- COALESCE(total_discount, 0) es un calculo en Gold, no una suposicion
    -- sobre el dato. Si total_discount es NULL, no se sabe el descuento;
    -- para poder calcular neto se asume 0, pero se marca en has_discount.
    gross_sales - COALESCE(total_discount, 0) AS net_sales,
    CASE WHEN total_discount > 0 THEN TRUE ELSE FALSE END AS has_discount,
    CASE WHEN gross_sales > 0 AND total_discount IS NOT NULL
         THEN total_discount / gross_sales ELSE NULL END AS discount_rate,
    line_count,
    active_line_count,
    void_lines,
    CASE WHEN has_order_void = 1 THEN TRUE ELSE FALSE END AS has_order_void,
    -- Orden anulada si todas las lineas son void o order_voided > 0
    CASE WHEN has_non_void_line = 0 OR has_order_void = 1 THEN TRUE ELSE FALSE END AS is_voided,
    -- Flag: el total varia entre lineas de la misma orden (error de datos)
    CASE WHEN distinct_totals > 1 THEN TRUE ELSE FALSE END AS has_inconsistent_total,
    -- Conciliacion: gross_sales - suma de importes de linea (deberia ser ~0)
    gross_sales - line_gross_sum AS gross_reconcile_diff,
    -- Conciliacion: total_discount - suma de item_discount (deberia ser ~0)
    COALESCE(total_discount, 0) - line_discount_sum AS discount_reconcile_diff,
    -- Canal de servicio
    CASE WHEN SIZE(service_modes) = 1 THEN service_modes[0]
         ELSE 'multiple/sin_dato' END AS service_mode
FROM order_agg;


-- ============================================================
-- 2. tb_gold_sales_daily: ventas diarias por sucursal
-- Agrega tb_gold_orders excluyendo ordenes anuladas.
-- Incluye ticket promedio, mediana y conteo de ordenes con descuento.
-- Para ventas mensuales: SELECT date_trunc('month', txn_date), ...
--   FROM tb_gold_sales_daily GROUP BY 1.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_sales_daily
COMMENT "Gold: ventas diarias por sucursal. Excluye ordenes anuladas. ticket_promedio = neto/ordenes."
AS
SELECT
    store_number,
    txn_date,
    date_trunc('month', txn_date) AS txn_month,
    dayofweek(txn_date)            AS day_of_week,
    COUNT(*)                       AS order_count,
    SUM(net_sales)                 AS gross_sales_sum,
    SUM(total_discount)            AS total_discount_sum,
    SUM(net_sales)                 AS net_sales_sum,
    SUM(CASE WHEN has_discount THEN 1 ELSE 0 END) AS orders_with_discount,
    SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END) AS orders_without_discount,
    -- Ticket promedio = ventas netas / numero de ordenes
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Mediana del ticket neto (aproximada para rendimiento distribuido)
    approx_percentile(net_sales, 0.5) AS median_ticket,
    -- Ticket promedio de ordenes con descuento
    CASE WHEN SUM(CASE WHEN has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_with_discount,
    -- Ticket promedio de ordenes sin descuento
    CASE WHEN SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN NOT has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_without_discount
FROM tb_gold_orders
WHERE NOT is_voided
GROUP BY store_number, txn_date;


-- ============================================================
-- 3. tb_gold_products: metricas por producto
-- Una fila por (pos_code, menu_item, report_group).
-- Solo incluye lineas activas (venta real, no anulada, qty > 0, precio > 0).
-- Moda = precio unitario mas frecuente del producto en todo el periodo.
-- Promedio = promedio del importe neto por linea (menu_price * qty - item_discount).
-- Periodo: desde la primera hasta la ultima aparicion en los datos.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_products
COMMENT "Gold: metricas por producto. Solo lineas activas (regular sale/discount, no void, qty>0, price>0)."
AS
WITH active_lines AS (
    SELECT
        pos_code,
        menu_item,
        report_group,
        store_number,
        txn_date,
        check_number,
        quantity,
        menu_price,
        item_discount,
        menu_price * quantity AS line_gross,
        (menu_price * quantity) - COALESCE(item_discount, 0) AS line_net
    FROM tb_daily_tld_silver
    WHERE transaction_type IN ('regular sale', 'discount')
      AND (item_voided IS NULL OR item_voided = 0)
      AND quantity > 0
      AND menu_price > 0
),
-- Frecuencia de precios para calcular la moda
price_freq AS (
    SELECT
        pos_code, menu_item, menu_price,
        COUNT(*) AS freq
    FROM active_lines
    GROUP BY pos_code, menu_item, menu_price
),
mode_price AS (
    SELECT pos_code, menu_item, menu_price AS mode_price
    FROM (
        SELECT
            pos_code, menu_item, menu_price,
            ROW_NUMBER() OVER (PARTITION BY pos_code, menu_item ORDER BY freq DESC, menu_price DESC) AS rn
        FROM price_freq
    ) ranked
    WHERE rn = 1
)
SELECT
    a.pos_code    AS sku,
    a.menu_item,
    a.report_group,
    SUM(a.quantity)                          AS total_units,
    COUNT(DISTINCT a.check_number)            AS total_orders,
    SUM(a.line_gross)                         AS total_gross,
    SUM(COALESCE(a.item_discount, 0))         AS total_discount,
    SUM(a.line_net)                           AS total_net,
    -- Precio unitario promedio (promedio simple de menu_price)
    AVG(a.menu_price)                         AS avg_unit_price,
    -- Moda del precio unitario (precio mas frecuente)
    m.mode_price,
    -- Promedio del importe neto por linea de venta
    AVG(a.line_net)                           AS avg_line_net,
    MIN(a.txn_date)                           AS first_seen,
    MAX(a.txn_date)                           AS last_seen,
    COUNT(DISTINCT a.store_number)            AS store_count
FROM active_lines a
LEFT JOIN mode_price m
    ON a.pos_code = m.pos_code AND a.menu_item = m.menu_item
GROUP BY a.pos_code, a.menu_item, a.report_group, m.mode_price;


-- ============================================================
-- 4. tb_gold_products_by_store: metricas por producto y sucursal
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_products_by_store
COMMENT "Gold: metricas por producto y sucursal. Solo lineas activas."
AS
SELECT
    store_number,
    pos_code    AS sku,
    menu_item,
    report_group,
    SUM(quantity)                            AS total_units,
    COUNT(DISTINCT check_number)              AS total_orders,
    SUM(menu_price * quantity)               AS total_gross,
    SUM(COALESCE(item_discount, 0))          AS total_discount,
    SUM((menu_price * quantity) - COALESCE(item_discount, 0)) AS total_net,
    AVG(menu_price)                          AS avg_unit_price,
    MIN(txn_date)                            AS first_seen,
    MAX(txn_date)                            AS last_seen
FROM tb_daily_tld_silver
WHERE transaction_type IN ('regular sale', 'discount')
  AND (item_voided IS NULL OR item_voided = 0)
  AND quantity > 0
  AND menu_price > 0
GROUP BY store_number, pos_code, menu_item, report_group;


-- ============================================================
-- 5. tb_gold_discounts: analisis de descuentos
-- Compara ordenes con descuento vs sin descuento por sucursal.
-- Comparacion descriptiva: NO implica causalidad. Una diferencia en
-- ticket promedio puede deberse al tipo de producto, la sucursal
-- o el dia, no solo al descuento.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_discounts
COMMENT "Gold: analisis de descuentos por sucursal y rango. Comparacion con/sin descuento (descriptiva, no causal)."
AS
WITH orders_with_range AS (
    SELECT
        store_number,
        net_sales,
        gross_sales,
        total_discount,
        has_discount,
        CASE
            WHEN NOT has_discount OR total_discount = 0 THEN '0: sin descuento'
            WHEN total_discount / gross_sales <= 0.10   THEN '1: hasta 10%'
            WHEN total_discount / gross_sales <= 0.20   THEN '2: 10%-20%'
            WHEN total_discount / gross_sales <= 0.30   THEN '3: 20%-30%'
            ELSE '4: mas de 30%'
        END AS discount_range
    FROM tb_gold_orders
    WHERE NOT is_voided
      AND gross_sales > 0
)
SELECT
    store_number,
    discount_range,
    COUNT(*)                    AS order_count,
    SUM(gross_sales)            AS gross_sales_sum,
    SUM(total_discount)         AS discount_sum,
    SUM(net_sales)              AS net_sales_sum,
    -- Ticket promedio del grupo
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Mediana del ticket neto
    approx_percentile(net_sales, 0.5) AS median_ticket
FROM orders_with_range
GROUP BY store_number, discount_range;


-- ============================================================
-- 6. tb_gold_discount_products: productos que reciben descuento
-- Lista los productos con item_discount > 0 y sus metricas.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_discount_products
COMMENT "Gold: productos que reciben descuento. Lineas con item_discount > 0."
AS
SELECT
    pos_code    AS sku,
    menu_item,
    report_group,
    COUNT(DISTINCT check_number)              AS orders_with_discount,
    SUM(quantity)                             AS total_units,
    SUM(menu_price * quantity)                AS gross_with_discount,
    SUM(item_discount)                        AS total_item_discount,
    SUM((menu_price * quantity) - item_discount) AS net_with_discount,
    -- Tasa de descuento promedio del producto
    CASE WHEN SUM(menu_price * quantity) > 0
         THEN SUM(item_discount) / SUM(menu_price * quantity)
         ELSE NULL END AS avg_discount_rate,
    MIN(txn_date)                             AS first_seen,
    MAX(txn_date)                             AS last_seen
FROM tb_daily_tld_silver
WHERE transaction_type IN ('regular sale', 'discount')
  AND (item_voided IS NULL OR item_voided = 0)
  AND quantity > 0
  AND menu_price > 0
  AND item_discount > 0
GROUP BY pos_code, menu_item, report_group;
