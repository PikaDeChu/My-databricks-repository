TACO BUENO — DATA PROCESSING AND ANALYTICS DOCUMENTATION

Overview

This document explains how Taco Bueno point-of-sale (POS) records become
analytical datasets for orders, sales, products, and discounts

The processing flow has three layers:

- Bronze reads CSV records and preserves their source information.
- Silver converts data types, normalizes text, applies quality expectations,
  and removes identical combinations of projected values.
- Gold summarizes the prepared data at order, store-day, product, and discount
  levels.

The main modeling distinction is between an order and an item line. An order
can contain several lines, while its total, tax, and order-level discount may
be repeated on every line. These repeated order amounts must not be added
across item lines.

The explanations describe the documented behavior, including its limitations.
Query examples assume the configured destination is workspace.default. Change
that prefix if the objects are published to another catalog or schema. Dates
in examples are illustrative filters, not confirmation of actual coverage.


1. DATA CLEANING LAYER

1.1 Raw ingestion — Bronze

Source directory:
    /Volumes/workspace/default/tacobueno/data

Output:
    workspace.default.tb_daily_tld_bronze

Bronze keeps the CSV business fields as STRING so that data can be ingested
before business-level type conversion. The documented schema contains 22
business fields: 19 base fields, report_group, tender_type, and total_rounding.
The source description identifies older 19-column files and newer 21-column
files; total_rounding is reserved for future compatibility. Actual header
alignment and missing-column behavior must be verified with representative
files.

Four additional columns support traceability:

- source_file: the source file name.
- source_file_path: the full source file path.
- source_file_mtime: the source file modification timestamp.
- ingestion_timestamp: the timestamp when ingestion is evaluated.

Bronze therefore exposes 26 columns. The business fields are text, while the
provenance timestamps are temporal values.

How the ingestion components work:

- CREATE OR REFRESH STREAMING TABLE declares the managed ingestion dataset.
- read_files reads records from the configured file directory.
- STREAM enables streaming ingestion through Auto Loader.
- format selects CSV as the input format.
- header indicates that the files contain a header row.
- schema declares the input column names and types explicitly.
- _metadata exposes file provenance.
- current_timestamp() records the ingestion evaluation time.
- AS assigns a readable output name to an expression.

The checkpoint tracks ingestion progress. During normal updates with the same
state, files already processed are not treated as newly arriving files. A full
refresh or reset of state can change this behavior. An empty file produces no
transaction rows and does not imply zero sales.

A file copied to another path can be ingested again. File discovery is not the
same as business-level deduplication. Bronze has no EXPECT quality rules in
the documented implementation.

1.2 Data preparation — Silver

Output:
    workspace.default.tb_daily_tld_silver

Silver uses three common table expressions, or CTEs. A CTE is a named query
inside a larger statement, not a separately stored table.

- bronze reads the ingestion dataset.
- typed converts types and normalizes text.
- filled replaces missing text with the existing label desconocido.

WITH introduces these named query stages. The final SELECT DISTINCT produces
the Silver result.

Type conversion:

- store_number becomes INT.
- check_number becomes BIGINT.
- txn_date becomes DATE using the source pattern M/d/yyyy.
- quantity becomes INT.
- Monetary fields and numeric void markers become DECIMAL(18,4).
- begin_time and end_time remain STRING.

DECIMAL(18,4) supports 18 total digits, including four decimal places. It is
used for check_total, total_discount, order_voided, tax, menu_price,
item_discount, item_voided, and total_rounding. Aggregations and divisions can
produce different result precision or scale.

TRY_CAST attempts the numeric conversions and returns NULL for invalid or
out-of-range values supported by these conversions. It does not automatically
clean currency symbols or unsupported number formatting.

TO_DATE interprets a source value such as 3/4/2026 as March 4, 2026. Unlike a
try-conversion, the documented TO_DATE expression can raise an error for an
invalid date, depending on the execution configuration.

Text normalization:

- TRIM removes spaces around a value.
- LOWER converts text to lowercase.
- IN checks whether the normalized text matches nan, none, null, or an empty
  string.
- CASE returns NULL for those missing-value labels; otherwise it returns the
  cleaned text.
- COALESCE returns the first non-null value and displays missing text as
  desconocido, meaning unknown.

The text replacement does not recover missing information. Numeric NULLs are
preserved in Silver. The string labels used by the original data processing
remain unchanged even though this documentation is in English.

1.3 Data quality checks

The five documented expectations are located in Silver:

- valid_store_number: store_number must not be NULL; a violation fails the
  affected update.
- valid_txn_date: txn_date must not be NULL; a violating row is dropped.
- valid_check_number: check_number must not be NULL; a violating row is dropped.
- valid_quantity: quantity must not be NULL and must be at least zero;
  violations are recorded and rows are retained.
- valid_menu_price: menu_price must not be NULL and must be at least zero;
  violations are recorded and rows are retained.

CONSTRAINT names the rule. EXPECT contains its Boolean condition. ON VIOLATION
selects the configured action. Without an explicit drop or fail action, the
expectation monitors violations while keeping the records.


1.4 Deduplication and void handling

SELECT DISTINCT compares every projected Silver column, including source_file,
after conversion and normalization. It removes identical projected rows, but
it can also collapse two legitimate identical item lines. A renamed copy of a
file has a different source_file and can remain in Silver.

Only source_file is propagated to Silver. The full path and ingestion metadata
remain in Bronze.

Void handling occurs in Gold rather than through a single Silver void-removal
stage. The order summary retains an is_voided flag; daily sales and order
discount summaries exclude flagged orders. Product views apply item-line
filters directly to Silver. Their order-void policy is not fully aligned with
the order summaries; see Maintenance and Updates.

Example — inspect row counts at their actual grains:

    SELECT 1 AS stage_order, 'Bronze' AS stage,
           'CSV record' AS row_grain, COUNT(*) AS row_count
    FROM workspace.default.tb_daily_tld_bronze
    UNION ALL
    SELECT 2, 'Silver', 'Projected item line', COUNT(*)
    FROM workspace.default.tb_daily_tld_silver
    UNION ALL
    SELECT 3, 'Gold orders', 'Order', COUNT(*)
    FROM workspace.default.tb_gold_orders
    UNION ALL
    SELECT 4, 'Included Gold orders', 'Order', COUNT(*)
    FROM workspace.default.tb_gold_orders
    WHERE NOT is_voided
    ORDER BY stage_order;



2. PRIMARY METRIC VIEW

Primary order-level dataset:
    workspace.default.tb_gold_orders

This is a materialized view containing ordinary SQL columns. It is not a
semantic Metric View requiring the MEASURE() function.

Its grain is one row per:
    (store_number, txn_date, check_number)

The same check_number on another day or at another store represents a
different order under this model. Confirm that this key matches POS behavior.

2.1 Available dimensions and identifiers

- store_number: store identifier.
- txn_date: transaction date.
- check_number: check or order identifier within the store and date.
- service_mode: the order's service mode, or multiple/sin_dato when the
  collected modes do not resolve to a single value.
- has_discount: whether the order-level discount is greater than zero.
- has_order_void: whether any line has a positive order_voided value.
- is_voided: the documented order-level exclusion flag.

Month and day of week can be derived from txn_date. Product names, product
codes, and report groups belong to Silver and the product views; they are not
columns of the order summary.

2.2 Available metrics and diagnostic fields

- gross_sales: MAX(check_total), taking the repeated order total once.
- total_discount: MAX(total_discount), taking the repeated order discount once.
- tax: MAX(tax), taking the repeated tax once; tax is not recalculated.
- net_sales: gross_sales - COALESCE(total_discount, 0).
- discount_rate: total_discount / gross_sales when gross_sales is positive and
  the discount is known; otherwise NULL.
- line_count: number of Silver rows grouped into the order.
- active_line_count: number of qualifying positive-price sale or discount lines.
- void_lines: number of lines with transaction_type = 'void'.
- has_inconsistent_total: whether more than one distinct non-null check_total
  occurs within the order.
- gross_reconcile_diff: order gross minus the qualifying line gross sum.
- discount_reconcile_diff: order discount, with missing values imputed as zero,
  minus the qualifying line discount sum.

The documented interpretation is that check_total is gross order revenue,
menu_price is a unit price, and item_discount is a line-level amount. These
business meanings must agree with the POS data contract. No cost data is
available, so the model does not calculate profit.

A missing order discount is treated as zero when calculating net_sales in
Gold. This is an assumption, even though Silver preserves the original NULL.
The has_discount flag also places zero, null, and negative discounts in its
FALSE category.

2.3 How the order summary is calculated

GROUP BY gathers lines using the complete order key. MAX prevents repeated
order totals from being added once per item, but it chooses the largest value
when conflicting totals exist; it does not choose the latest version.

COUNT(*) counts lines. COUNT(DISTINCT check_total) counts distinct known totals.
SUM(CASE WHEN ... THEN ... ELSE ... END) performs conditional calculations,
such as counting void lines or summing eligible item amounts.

COLLECT_SET gathers distinct service modes. SIZE counts them, and [0] accesses
the only value when there is one. The array order is not otherwise guaranteed.

Example — daily sales by service mode:

    SELECT txn_date, service_mode,
           SUM(net_sales) AS net_sales,
           COUNT(*) AS order_count,
           COUNT(net_sales) AS orders_with_known_net
    FROM workspace.default.tb_gold_orders
    WHERE NOT is_voided
      AND txn_date >= DATE '2025-01-01'
      AND txn_date < DATE '2025-04-01'
    GROUP BY txn_date, service_mode
    ORDER BY txn_date, service_mode;

The examples retain the current is_voided policy. They do not repair its known
classification issue. Sums can be incomplete when inputs are NULL; the known
net count exposes part of that coverage limitation.


3. AGGREGATED TABLES

The analytical outputs below are materialized views. Their stored results
support different grains and cannot be combined without considering those
grain differences.

3.1 Store-level aggregates

Daily store summary:
    workspace.default.tb_gold_sales_daily

Grain:
    One row per store_number and txn_date with included orders.

Main fields:

- txn_month and day_of_week: derived date attributes.
- order_count: included order count.
- gross_sales_sum, total_discount_sum, and net_sales_sum: monetary summaries.
- orders_with_discount and orders_without_discount: counts based on has_discount.
- avg_ticket: net sales divided by order count.
- median_ticket: approximate median of order net sales.
- avg_ticket_with_discount and avg_ticket_without_discount: group averages.

The current gross_sales_sum expression sums net_sales. Consequently, that
column must not be interpreted as a validated gross-sales total. The previous
documentation identifies SUM(gross_sales) as the intended correction; that
correction is not applied by this document.

Example — top stores by net sales for a selected period:

    SELECT store_number,
           SUM(net_sales_sum) AS net_sales,
           SUM(order_count) AS order_count,
           SUM(net_sales_sum) / NULLIF(SUM(order_count), 0) AS avg_ticket
    FROM workspace.default.tb_gold_sales_daily
    WHERE txn_date >= DATE '2025-01-01'
      AND txn_date < DATE '2026-01-01'
    GROUP BY store_number
    ORDER BY net_sales DESC
    LIMIT 10;

NULLIF returns NULL when its two arguments are equal, avoiding a zero divisor
in this example. The average follows the documented total-net/total-order
formula, including its limitations when net values are missing.

3.2 Top products

Product summary:
    workspace.default.tb_gold_products

Product-by-store summary:
    workspace.default.tb_gold_products_by_store

The global product grain is (sku, menu_item, report_group). The store view adds
store_number. Both summarize the entire loaded period rather than individual
days.

Eligible lines must have transaction_type in ('regular sale', 'discount'),
item_voided equal to zero or NULL, quantity greater than zero, and menu_price
greater than zero. Zero-price combo components and zero-quantity modifiers are
not included in these product metrics.

Main calculations:

- total_units: sum of eligible quantities.
- total_gross: sum of menu_price * quantity.
- total_discount: sum of item discounts, imputing missing discounts as zero.
- total_net: gross line amounts minus the imputed line discounts.
- avg_unit_price: simple average of line-level unit prices, not quantity-weighted.
- total_orders: distinct check_number count in the current implementation.
- first_seen and last_seen: earliest and latest eligible transaction dates.

The global product view also provides mode_price, avg_line_net, and store_count.
The mode is calculated by counting lines at each price, then using ROW_NUMBER
with PARTITION BY product code and name. ORDER BY frequency descending selects
the most frequent price, and price descending breaks ties in favor of the
higher price. report_group is not part of the mode partition, so the resulting
mode is shared across report groups for the same code and name.

Example — top 15 product groups by line net sales:

    SELECT sku, menu_item, report_group, total_units, total_net
    FROM workspace.default.tb_gold_products
    ORDER BY total_net DESC
    LIMIT 15;

The product order count can undercount because check numbers repeat across
dates and stores. Product counts must also not be summed to obtain a total
order count: one order can contain several products.

Filtering first_seen and last_seen does not recompute product sales for a date
range. Period-specific product analysis must be derived from dated line data
using an explicitly agreed set of inclusion rules.

3.3 Year-over-year growth

The previous documentation does not define dedicated year-over-year growth
views. Store-level net-sales growth can be derived from tb_gold_sales_daily or
tb_gold_orders using comparable periods.

Definition:
    Growth percentage = ((current-period sales / prior-period sales) - 1) * 100

For a valid comparison:

- Use matching date windows in both years.
- Confirm that both periods have adequate data coverage.
- Decide whether to compare all stores or the same set of stores in both years.
- Return NULL or an explicitly agreed status when the prior period is missing
  or has zero sales.
- Apply the same void and missing-value policies in both periods.

Report-group and item growth require dated product-level calculations from
Silver. The all-period product views do not contain separate annual totals.

3.4 Discount analysis

Order discount summary:
    workspace.default.tb_gold_discounts

Grain:
    One row per store_number and discount_range across the loaded period.

This view excludes flagged voided orders and requires gross_sales > 0. It
reports order_count, gross_sales_sum, discount_sum, net_sales_sum, avg_ticket,
and median_ticket.

The existing output labels are preserved:

- '0: sin descuento': no discount under the current flag logic.
- '1: hasta 10%': positive discount up to 10%.
- '2: 10%-20%': discount greater than 10% and up to 20%.
- '3: 20%-30%': discount greater than 20% and up to 30%.
- '4: mas de 30%': discount greater than 30%.

The first CASE condition that evaluates to true determines the range. Unknown
and negative discounts also enter the first category under the current logic.

Example — inspect discount ranges by store:

    SELECT store_number, discount_range, order_count,
           gross_sales_sum, discount_sum, net_sales_sum, avg_ticket
    FROM workspace.default.tb_gold_discounts
    ORDER BY store_number, discount_range;

Discounted product summary:
    workspace.default.tb_gold_discount_products

This view applies the eligible product-line filters and additionally requires
item_discount > 0. It reports orders_with_discount, total_units,
gross_with_discount, total_item_discount, net_with_discount,
avg_discount_rate, first_seen, and last_seen.

Its discount rate is a ratio of sums: total item discount divided by total
line gross. It is not the simple average of individual line percentages.
Order-level discounts without line allocation are not captured by this view.

A comparison of discounted and non-discounted sales is descriptive. Differences
can reflect product mix, store, date, or other factors; they do not establish
that discounts caused higher sales or higher profit.


4. COMMON USE CASES

4.1 Monthly trend analysis

Use dated order or daily-store data. Recompute the average from total sales and
total orders rather than averaging daily averages.

    SELECT DATE_TRUNC('month', txn_date) AS sales_month,
           SUM(net_sales_sum) AS net_sales,
           SUM(order_count) AS order_count,
           SUM(net_sales_sum) / NULLIF(SUM(order_count), 0) AS avg_ticket
    FROM workspace.default.tb_gold_sales_daily
    WHERE txn_date >= DATE '2025-01-01'
      AND txn_date < DATE '2026-01-01'
    GROUP BY DATE_TRUNC('month', txn_date)
    ORDER BY sales_month;

DATE_TRUNC labels each date with the beginning of its month. GROUP BY collects
those dates into monthly groups. ORDER BY returns the months chronologically.

4.2 Daypart analysis

A daypart dimension such as Morning, Lunch, or Dinner is not defined in the
previous documentation. begin_time and end_time remain unvalidated strings.
Before adding this analysis, define the relevant event time, its format and
time zone, the treatment of midnight, and the boundaries of each daypart.

For an available time-based analysis, use transaction date or day of week.
DAYOFWEEK uses 1 for Sunday through 7 for Saturday.

4.3 Channel analysis by hour

service_mode is available, but channel_group, pop_channel, and hour_of_day are
not documented output columns. Service modes are normalized text, not a
verified mapping to Drive Thru, Takeout, Dine-In, and Delivery/Online.

A channel-by-hour analysis first requires validated time parsing and a service
mode mapping. The daily service-mode query in Section 2 is available without
introducing those unimplemented dimensions.

4.4 Store performance comparison

Example — compare stores within each recorded service mode:

    SELECT store_number, service_mode,
           SUM(net_sales) AS net_sales,
           COUNT(*) AS order_count,
           AVG(net_sales) AS avg_ticket_known,
           COUNT(net_sales) AS orders_with_known_net
    FROM workspace.default.tb_gold_orders
    WHERE NOT is_voided
      AND txn_date >= DATE '2025-01-01'
      AND txn_date < DATE '2026-01-01'
    GROUP BY store_number, service_mode
    ORDER BY service_mode, net_sales DESC;

AVG ignores NULL values. Therefore avg_ticket_known averages only known net
amounts and can differ from the original net-sales/total-orders formula. Its
name and coverage count make that distinction explicit.


5. QUERY RULES AND BEST PRACTICES

5.1 Use the correct object type

The documented analytical objects are ordinary materialized views. Use SQL
columns and standard aggregates such as SUM, COUNT, AVG, MIN, and MAX.
MEASURE() is used for semantic Metric Views and is not needed for these views.

Explicit GROUP BY columns are used in the examples. GROUP BY ALL is not a
requirement for this project. SELECT * is valid for ordinary views, but named
columns make analytical queries easier to review and maintain.

5.2 Respect the grain

Use tb_gold_orders for order-level revenue and counts. Do not sum repeated
check_total, total_discount, or tax values directly across Silver item lines.
Do not confuse line_count, active_line_count, and total_units.

Count distinct orders with the complete key:
    (store_number, txn_date, check_number)

When joining lines to orders, join on all three columns. Otherwise, rows and
amounts can multiply or match the wrong order.

5.3 Preserve NULL meaning

SUM, AVG, MIN, and MAX ignore null inputs; when no known values exist, their
results can be NULL. COUNT(*) counts rows, while COUNT(column) counts non-null
values. Use IS NULL and IS NOT NULL rather than comparing a value with = NULL.

COALESCE(value, 0) makes an explicit zero-imputation assumption. A missing
amount must not automatically be described as a confirmed zero.

5.4 Use date ranges at the appropriate grain

Use typed date filters such as:

    WHERE txn_date >= DATE '2025-01-01'
      AND txn_date < DATE '2026-01-01'

Half-open intervals include the start and exclude the next period's start.
They avoid ambiguity at period boundaries. Apply them to dated source views,
not to an all-period aggregate that has already discarded its date grain.

5.5 Aggregate ratios and medians correctly

- Compute a combined ticket as total net sales divided by the relevant order
  count; do not take an unweighted average of daily ticket averages.
- Compute a combined discount rate from compatible discount and gross totals,
  using the same population and missing-value policy.
- Do not sum store_count across products to obtain a unique store count.
- Do not average daily medians to obtain the overall median.
- approx_percentile(value, 0.5) estimates the median; it is not the mean or mode.

5.6 Use grouping, filtering, and ordering deliberately

WHERE filters input rows. GROUP BY creates the analytical groups. HAVING filters
aggregated groups. ORDER BY sorts the final results, and LIMIT bounds the
number of returned rows. Backticks can quote identifiers; single quotes
represent text literals in these examples.

Use a CTE when a second aggregation or filter depends on an already aggregated
result. Each stage should have a clearly stated grain.


6. KEY PERFORMANCE INDICATORS

The previous documentation supports the following indicators:

- Net sales: SUM(net_sales) across included order rows, subject to the current
  missing-discount and void policies.
- Gross sales: SUM(gross_sales) from the order view; the current daily
  gross_sales_sum column contains the known formula issue described above.
- Total orders: COUNT(*) on the included order view, or SUM(order_count) over
  non-overlapping daily-store groups.
- Average ticket: net sales divided by the intended order count; distinguish
  all-order and known-net denominators when values are missing.
- Median ticket: approximate 50th percentile of the relevant order net amounts.
- Discount amount: order discounts counted once per order, or allocated item
  discounts at line grain; these are different measures.
- Discount rate: discount divided by gross under a consistent population.
- Sold product units: sum of eligible quantities; excludes zero-price components
  and uses the documented product inclusion rules.
- Active stores: COUNT(DISTINCT store_number) over the selected included orders.
- Product price mode: most frequent unit price by line frequency under the
  documented product partition and tie-breaking rule.


7. DATA COVERAGE AND QUALITY

No executed row-count report or verified start/end coverage was supplied with
the previous explanatory documentation. Values such as 85.3 million raw rows,
24% duplicate removal, and a fixed January 2025–September 2026 period must not
be presented as confirmed results of this model.

Measure coverage from the current data instead:

    SELECT MIN(txn_date) AS first_transaction_date,
           MAX(txn_date) AS last_transaction_date,
           COUNT(*) AS silver_row_count,
           COUNT(DISTINCT store_number) AS distinct_stores,
           SUM(CASE WHEN check_total IS NULL THEN 1 ELSE 0 END)
               AS rows_missing_check_total,
           SUM(CASE WHEN total_discount IS NULL THEN 1 ELSE 0 END)
               AS rows_missing_order_discount
    FROM workspace.default.tb_daily_tld_silver;

The two missing-value counts are line counts, not distinct order counts.
Earliest and latest dates do not prove that every intervening date or store
has complete coverage. Missing days are not automatically zero-sales days.

Inspect the following quality areas:

- CSV header alignment across expected file versions.
- Invalid dates and failed numeric conversions.
- Missing order totals, discounts, and taxes.
- Repeated check numbers across dates and stores.
- Conflicting totals within an order.
- Renamed file copies and legitimate identical item lines.
- Mixed sale/void orders and order-level void flags.
- Agreement between order and product inclusion policies.

Quality expectation metrics can be inspected through the pipeline's supported
monitoring interface or event log. The SQL comments themselves do not execute
validation, and diagnostic flags do not automatically quarantine records.



8. CONTACT AND SUPPORT

For questions about the pipeline or data access, contact the Taco Bueno Analytics team.
