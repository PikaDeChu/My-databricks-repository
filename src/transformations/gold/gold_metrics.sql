-- ============================================================
-- GOLD LAYER: Taco Bueno sales metrics
-- File: src/transformations/gold/gold_metrics.sql
-- ============================================================
--
-- PURPOSE:
--   Calculates Taco Bueno business metrics from Silver.
--   Tables created (all in workspace.default):
--
--   1. tb_gold_orders            -- One row per unique order
--   2. tb_gold_sales_daily       -- Daily sales by store
--   3. tb_gold_products          -- Product metrics (units, average price, mode)
--   4. tb_gold_products_by_store -- Metrics by product and store
--   5. tb_gold_discounts         -- Discount analysis (with vs. without discounts)
--   6. tb_gold_discount_products -- Products receiving discounts
--
-- KEY DEFINITIONS (verified against actual data):
--   * Order key = (store_number, txn_date, check_number).
--     check_number is NOT unique across dates; it repeats across days.
--   * check_total = Order total (gross amount before discounts).
--     Repeated on every order line; NOT summed across lines.
--   * total_discount = Total order discount (repeated on each line).
--   * menu_price = Item UNIT price (not the line amount).
--     Gross line amount = menu_price * quantity.
--   * tax = Order tax (repeated on each line).
--     Tax is calculated on the net amount (total - discount).
--   * Gross sales = check_total (once per order).
--   * Net sales = check_total - total_discount.
--   * Average order value = average net sales per order.
--   * Product costs are unavailable; profits are not calculated.
--
-- VOID HANDLING:
--   * transaction_type = 'void' -> voided line.
--   * item_voided > 0 -> voided item.
--   * order_voided > 0 -> voided order.
--   * Fully voided orders are excluded from sales metrics
--     but retained in tb_gold_orders with is_voided = TRUE.
--
-- ITEM HANDLING:
--   * Product metrics include only active lines:
--     transaction_type IN ('regular sale', 'discount') AND
--     item_voided = 0 (or NULL) AND quantity > 0 AND menu_price > 0.
--   * Combo components (menu_price = 0) and modifiers
--     (quantity = 0) are not counted as units sold.
--
-- COMPARISONS WITH/WITHOUT DISCOUNTS:
--   * The comparison is descriptive: it does not imply causation.
--     A difference in average order value may be due to the product
--     type, store, or day, rather than the discount alone.
-- ============================================================


-- ============================================================
-- 1. tb_gold_orders: order-level summary
-- One row per (store_number, txn_date, check_number).
-- check_total, total_discount, and tax are taken only once (MAX)
-- because they are repeated on every order line in Silver.
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
   -- Net sales = gross sales - discount.
    -- COALESCE(total_discount, 0) is a calculation in Gold, not an assumption
    -- about the data. If total_discount is NULL, the discount is unknown;
    -- 0 is assumed to calculate net sales, but this is flagged in has_discount.
    gross_sales - COALESCE(total_discount, 0) AS net_sales,
    CASE WHEN total_discount > 0 THEN TRUE ELSE FALSE END AS has_discount,
    CASE WHEN gross_sales > 0 AND total_discount IS NOT NULL
         THEN total_discount / gross_sales ELSE NULL END AS discount_rate,
    line_count,
    active_line_count,
    void_lines,
    CASE WHEN has_order_void = 1 THEN TRUE ELSE FALSE END AS has_order_void,
    -- Order is voided if all lines are void or order_voided > 0
    CASE WHEN has_non_void_line = 0 OR has_order_void = 1 THEN TRUE ELSE FALSE END AS is_voided,
    -- Flag: the total varies across lines of the same order (data error)
    CASE WHEN distinct_totals > 1 THEN TRUE ELSE FALSE END AS has_inconsistent_total,
    -- Reconciliation: gross_sales - sum of line amounts (should be ~0)
    gross_sales - line_gross_sum AS gross_reconcile_diff,
    -- Reconciliation: total_discount - sum of item_discount (should be ~0)
    COALESCE(total_discount, 0) - line_discount_sum AS discount_reconcile_diff,
    -- Service channel
    CASE WHEN SIZE(service_modes) = 1 THEN service_modes[0]
         ELSE 'multiple/sin_dato' END AS service_mode
FROM order_agg;


-- ============================================================
-- 2. tb_gold_sales_daily: daily sales by store
-- Aggregates tb_gold_orders, excluding voided orders.
-- Includes average order value, median, and count of discounted orders.
-- For monthly sales: SELECT date_trunc('month', txn_date), ...
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
    -- Average order value = net sales / number of orders
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Median net order value (approximate for distributed processing performance)
    approx_percentile(net_sales, 0.5) AS median_ticket,
    -- Average order value for discounted orders
    CASE WHEN SUM(CASE WHEN has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_with_discount,
    -- Average order value for orders without discounts
    CASE WHEN SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN NOT has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_without_discount
FROM tb_gold_orders
WHERE NOT is_voided
GROUP BY store_number, txn_date;


-- ============================================================
-- 3. tb_gold_products: product metrics
-- One row per (pos_code, menu_item, report_group).
-- Includes only active lines (actual sale, not voided, qty > 0, price > 0).
-- Mode = most frequent unit price of the product over the entire period.
-- Average = average net line amount (menu_price * qty - item_discount).
-- Period: from the first to the last occurrence in the data.
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
-- Price frequency for calculating the mode
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
    -- Average unit price (simple average of menu_price)
    AVG(a.menu_price)                         AS avg_unit_price,
    -- Unit price mode (most frequent price) 
    m.mode_price,
    -- Unit price mode (most frequent price)  
    AVG(a.line_net)                           AS avg_line_net,
    MIN(a.txn_date)                           AS first_seen,
    MAX(a.txn_date)                           AS last_seen,
    COUNT(DISTINCT a.store_number)            AS store_count
FROM active_lines a
LEFT JOIN mode_price m
    ON a.pos_code = m.pos_code AND a.menu_item = m.menu_item
GROUP BY a.pos_code, a.menu_item, a.report_group, m.mode_price;


-- ============================================================
-- 4. tb_gold_products_by_store: metrics by product and store
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
-- 5. tb_gold_discounts: discount analysis
-- Compares orders with and without discounts by store.
-- Descriptive comparison: does NOT imply causation. A difference in
-- average order value may be due to the product type, store,
-- or day, rather than the discount alone.
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
    -- Average order value for the group 
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Median net order value
    approx_percentile(net_sales, 0.5) AS median_ticket
FROM orders_with_range
GROUP BY store_number, discount_range;


-- ============================================================
-- 6. tb_gold_discount_products: products receiving discounts
-- Lists products with item_discount > 0 and their metrics.
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
    -- Average product discount rate 
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
