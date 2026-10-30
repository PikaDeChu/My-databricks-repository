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
-- SQL source for a Lakeflow pipeline in Databricks; configure the target catalog and schema.
-- Single-line explanatory comments; the original logic is preserved.
-- Depends on Silver and creates six Gold views; contains no EXPECT expectations.

-- ============================================================================
-- GOLD: creates six views to analyze orders, daily sales, products, and discounts.
-- Original file: src/transformations/gold/gold_metrics.sql
-- ============================================================================

-- 1 ORDERS. One row per store, date, and check number. Basis for sales and discounts. Product views in the supplied code read Silver directly.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_orders
COMMENT "Gold: order-level summary. Key = (store_number, txn_date, check_number). check_total is not summed across lines."
AS
-- CTE that groups lines into an order. It does not deduplicate files.
WITH order_agg AS (
    SELECT
        store_number,
        txn_date,
        check_number,
        -- MAX takes the repeated total once. It does not select the latest version. If values differ, it takes the largest and may hide inconsistencies.
        MAX(check_total)                                  AS gross_sales,
        MAX(total_discount)                               AS total_discount,
        MAX(tax)                                          AS tax,
        -- Counts Silver rows, not units or original lines before DISTINCT.
        COUNT(*)                                          AS line_count,
        -- Counts distinct NON-null totals. NULL together with 100 does not count as two values.
        COUNT(DISTINCT check_total)                       AS distinct_totals,
        -- CASE produces 1 for each void line; SUM counts those lines.
        SUM(CASE WHEN transaction_type = 'void' THEN 1 ELSE 0 END) AS void_lines,
        -- NOTE: MIN is incorrect for checking whether a non-void line EXISTS. A sale and a void produce MIN(1,0)=0 and mark the entire order as void below. MAX would detect existence.
        MIN(CASE WHEN transaction_type != 'void' THEN 1 ELSE 0 END) AS has_non_void_line,
        -- MAX over 0/1 indicates whether any row marks the order as void.
        MAX(CASE WHEN order_voided > 0 THEN 1 ELSE 0 END)  AS has_order_void,
        -- Conditional sum. IN restricts types and AND requires the remaining conditions. OR allows null or zero item_voided, which is a business decision.
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  AND quantity > 0
                 -- Gross line amount: unit price times quantity; does not sum the repeated check_total.
                 THEN menu_price * quantity ELSE 0 END)   AS line_gross_sum,
        -- Conditional sum. IN restricts types and AND requires the remaining conditions. OR allows null or zero item_voided, which is a business decision.
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  AND quantity > 0
                 -- Line discount; COALESCE imputes zero when missing. NOTE: this imputation IS an assumption about the missing value.
                 THEN COALESCE(item_discount, 0) ELSE 0 END) AS line_discount_sum,
        -- Conditional sum. IN restricts types and AND requires the remaining conditions. OR allows null or zero item_voided, which is a business decision.
        SUM(CASE WHEN transaction_type IN ('regular sale', 'discount')
                  AND (item_voided IS NULL OR item_voided = 0)
                  -- The active count additionally requires a positive price and counts lines, not units.
                  AND quantity > 0 AND menu_price > 0
                 THEN 1 ELSE 0 END)                        AS active_line_count,
        -- Array of unique service modes; its order is not guaranteed.
        COLLECT_SET(service_mode)                         AS service_modes
    FROM tb_daily_tld_silver
    WHERE store_number IS NOT NULL
      AND txn_date IS NOT NULL
      AND check_number IS NOT NULL
    -- Complete order key. Identical check numbers on different days or at different stores represent different orders.
    GROUP BY store_number, txn_date, check_number
)
SELECT
    store_number,
    txn_date,
    check_number,
    gross_sales,
    total_discount,
    tax,
    -- Net = gross - discount, assuming a missing discount equals zero.
    gross_sales - COALESCE(total_discount, 0) AS net_sales,
    -- NOTE: FALSE combines zero, NULL, and negative discounts. There is no separate flag for an unknown discount.
    CASE WHEN total_discount > 0 THEN TRUE ELSE FALSE END AS has_discount,
    -- Proportional rate, not a percentage multiplied by one hundred. Avoids division by zero.
    CASE WHEN gross_sales > 0 AND total_discount IS NOT NULL
         THEN total_discount / gross_sales ELSE NULL END AS discount_rate,
    line_count,
    active_line_count,
    void_lines,
    CASE WHEN has_order_void = 1 THEN TRUE ELSE FALSE END AS has_order_void,
    -- Intended to mark an order as void when all lines are void or the order is flagged. NOTE: the incorrect MIN flag also excludes mixed orders.
    CASE WHEN has_non_void_line = 0 OR has_order_void = 1 THEN TRUE ELSE FALSE END AS is_voided,
    -- Diagnostic flag: does not discard orders or detect entirely null totals.
    CASE WHEN distinct_totals > 1 THEN TRUE ELSE FALSE END AS has_inconsistent_total,
    -- Gross reconciliation. Whether the difference should be close to zero depends on definitions and filters.
    gross_sales - line_gross_sum AS gross_reconcile_diff,
    -- Discount reconciliation with missing values imputed. No tolerance or rejection is applied.
    COALESCE(total_discount, 0) - line_discount_sum AS discount_reconcile_diff,
    -- SIZE counts service modes. [0] selects the sole value using zero-based indexing. The desconocido label counts as a distinct value because it is no longer NULL.
    CASE WHEN SIZE(service_modes) = 1 THEN service_modes[0]
         ELSE 'multiple/sin_dato' END AS service_mode
FROM order_agg;

-- 2 DAILY SALES. One row per store and day with included orders.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_sales_daily
COMMENT "Gold: daily sales by store. Excludes voided orders. Average ticket = net sales / orders."
AS
SELECT
    store_number,
    txn_date,
    -- Start of the month as TIMESTAMP. This does not itself change the daily grouping.
    date_trunc('month', txn_date) AS txn_month,
    -- Day of the week: 1 Sunday, 2 Monday, ..., 7 Saturday.
    dayofweek(txn_date)            AS day_of_week,
    COUNT(*)                       AS order_count,
    -- NOTE: formula error. The gross alias sums net sales. The expected expression would be SUM(gross_sales) AS gross_sales_sum.
    SUM(net_sales)                 AS gross_sales_sum,
    SUM(total_discount)            AS total_discount_sum,
    SUM(net_sales)                 AS net_sales_sum,
    -- Order counts by flag. Unknown discounts fall into the no-discount group.
    SUM(CASE WHEN has_discount THEN 1 ELSE 0 END) AS orders_with_discount,
    SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END) AS orders_without_discount,
    -- Ticket = sum of net sales / order count. NOTE: SUM skips NULL net sales, but COUNT(*) includes those orders.
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Estimates the 50th percentile; it is neither a mean nor a mode, nor an exact interpolated median.
    approx_percentile(net_sales, 0.5) AS median_ticket,
    -- Average for the discounted group only; returns NULL when there are no orders in that group.
    CASE WHEN SUM(CASE WHEN has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_with_discount,
    -- Average for the non-discounted group; includes unknown discounts under the current logic.
    CASE WHEN SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END) > 0
         THEN SUM(CASE WHEN NOT has_discount THEN net_sales ELSE 0 END) /
              SUM(CASE WHEN NOT has_discount THEN 1 ELSE 0 END)
         ELSE NULL END AS avg_ticket_without_discount
FROM tb_gold_orders
-- Excludes orders based on the calculated void flag, with its limitations.
WHERE NOT is_voided
GROUP BY store_number, txn_date;

-- 3 PRODUCTS. One row per code, name, and report_group across the entire period.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_products
COMMENT "Gold: product metrics. Active lines only (regular sale/discount, not voided, qty>0, price>0)."
AS
-- CTE of active lines with positive price and quantity. NOTE: it neither checks the order-level is_voided flag nor filters order_voided.
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
        -- Gross line amount; item_discount is subtracted once per line below.
        menu_price * quantity AS line_gross,
        (menu_price * quantity) - COALESCE(item_discount, 0) AS line_net
    FROM tb_daily_tld_silver
    WHERE transaction_type IN ('regular sale', 'discount')
      AND (item_voided IS NULL OR item_voided = 0)
      AND quantity > 0
      AND menu_price > 0
),
-- PRICE frequencies BY LINE. COUNT(*) is not weighted by quantity. NOTE: report_group is not part of this frequency calculation.
price_freq AS (
    SELECT
        pos_code, menu_item, menu_price,
        -- Counts Silver rows, not units or original lines before DISTINCT.
        COUNT(*) AS freq
    FROM active_lines
    GROUP BY pos_code, menu_item, menu_price
),
-- Selects the most frequent price for each code and name.
mode_price AS (
    SELECT pos_code, menu_item, menu_price AS mode_price
    FROM (
        SELECT
            pos_code, menu_item, menu_price,
            -- OVER defines the window; PARTITION BY restarts for each product. ORDER BY freq DESC prioritizes frequency; descending price breaks ties in favor of the highest price.
            ROW_NUMBER() OVER (PARTITION BY pos_code, menu_item ORDER BY freq DESC, menu_price DESC) AS rn
        FROM price_freq
    -- ranked is the alias of the subquery that has already calculated rn.
    ) ranked
    -- Keeps a single winner. Does not return all tied modes.
    WHERE rn = 1
)
SELECT
    -- Alias for the existing code. Does not generate a new product key.
    a.pos_code    AS sku,
    a.menu_item,
    a.report_group,
    SUM(a.quantity)                          AS total_units,
    -- NOTE: undercounts orders by ignoring store and date. Proposal: COUNT(DISTINCT a.store_number, a.txn_date, a.check_number).
    COUNT(DISTINCT a.check_number)            AS total_orders,
    SUM(a.line_gross)                         AS total_gross,
    SUM(COALESCE(a.item_discount, 0))         AS total_discount,
    SUM(a.line_net)                           AS total_net,
    -- Simple average across lines. It is not weighted by units.
    AVG(a.menu_price)                         AS avg_unit_price,
    m.mode_price,
    -- Average net amount PER LINE; not the average ticket per order.
    AVG(a.line_net)                           AS avg_line_net,
    -- First and last observed dates among lines that passed the filters.
    MIN(a.txn_date)                           AS first_seen,
    MAX(a.txn_date)                           AS last_seen,
    -- Number of distinct stores with that product and group.
    COUNT(DISTINCT a.store_number)            AS store_count
FROM active_lines a
-- LEFT JOIN preserves the lines and attaches the mode; a and m are source aliases. The mode is shared across report_group values because the join omits that field.
LEFT JOIN mode_price m
    ON a.pos_code = m.pos_code AND a.menu_item = m.menu_item
GROUP BY a.pos_code, a.menu_item, a.report_group, m.mode_price;

-- 4 PRODUCTS BY STORE. Same main totals, grouped by store. Does not calculate a mode. Also omits order-level void filtering.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_products_by_store
COMMENT "Gold: metrics by product and store. Active lines only."
AS
SELECT
    store_number,
    pos_code    AS sku,
    menu_item,
    report_group,
    SUM(quantity)                            AS total_units,
    -- NOTE: within each store, the date of each check must also be distinguished.
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

-- 5 ORDER DISCOUNTS. One row per store and discount range across the entire period. Descriptive comparison; does not estimate causality or profit.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_discounts
COMMENT "Gold: discount analysis by store and range. Comparison with/without discounts (descriptive, not causal)."
AS
-- Classifies orders; the final query then aggregates each range.
WITH orders_with_range AS (
    SELECT
        store_number,
        net_sales,
        gross_sales,
        total_discount,
        has_discount,
        CASE
            -- The first true condition wins. NOTE: NULL and negative discounts also fall into the no-discount group.
            WHEN NOT has_discount OR total_discount = 0 THEN '0: sin descuento'
            -- Rates up to 10%, then 20%, then 30%; upper bounds are inclusive.
            WHEN total_discount / gross_sales <= 0.10   THEN '1: hasta 10%'
            WHEN total_discount / gross_sales <= 0.20   THEN '2: 10%-20%'
            WHEN total_discount / gross_sales <= 0.30   THEN '3: 20%-30%'
            ELSE '4: mas de 30%'
        END AS discount_range
    FROM tb_gold_orders
    WHERE NOT is_voided
      -- Excludes zero, negative, and null gross sales; the population differs from the daily summary.
      AND gross_sales > 0
)
SELECT
    store_number,
    discount_range,
    COUNT(*)                    AS order_count,
    SUM(gross_sales)            AS gross_sales_sum,
    SUM(total_discount)         AS discount_sum,
    SUM(net_sales)              AS net_sales_sum,
    -- Ticket = sum of net sales / order count. NOTE: SUM skips NULL net sales, but COUNT(*) includes those orders.
    CASE WHEN COUNT(*) > 0 THEN SUM(net_sales) / COUNT(*) ELSE NULL END AS avg_ticket,
    -- Estimates the 50th percentile; it is neither a mean nor a mode, nor an exact interpolated median.
    approx_percentile(net_sales, 0.5) AS median_ticket
FROM orders_with_range
GROUP BY store_number, discount_range;

-- 6 DISCOUNTED PRODUCTS. Active lines with a positive item discount only. Excludes order-level discounts that are not allocated to a line.
CREATE OR REFRESH MATERIALIZED VIEW tb_gold_discount_products
COMMENT "Gold: products receiving discounts. Lines with item_discount > 0."
AS
SELECT
    pos_code    AS sku,
    menu_item,
    report_group,
    -- NOTE: the complete order key is required to avoid undercounting.
    COUNT(DISTINCT check_number)              AS orders_with_discount,
    SUM(quantity)                             AS total_units,
    SUM(menu_price * quantity)                AS gross_with_discount,
    SUM(item_discount)                        AS total_item_discount,
    SUM((menu_price * quantity) - item_discount) AS net_with_discount,
    -- Ratio of sums: total discount / total gross. Not a simple average of percentages; weighted by line gross amounts.
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
  -- Requires a positive discount. NULL, zero, and negative values are excluded.
  AND item_discount > 0
GROUP BY pos_code, menu_item, report_group;

