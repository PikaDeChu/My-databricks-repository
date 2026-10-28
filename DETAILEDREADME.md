# My-databricks-repository
Overview

This SQL pipeline analyzes Taco Bueno sales data, providing key performance metrics, discount analysis, and product trends. Data is stored in Databricks and processed through multiple aggregation layers.
Pipeline Architecture

# 1. Data Cleaning Layer

The pipeline begins with a data quality process documented in cleaning_pipeline_funnel_funnel:
Raw ingest: 85,273,331 initial records
After dedup: 65,149,963 records (24% duplicate removal)
After void removal: 64,762,862 final records
-- Example: Verify cleaning funnel
SELECT `stage`, `row_count`
FROM `cleaning_pipeline_funnel_funnel`
ORDER BY `stage_order`;
2. Primary Metric View

Table: __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
Available Dimensions:
date_clean, month - Temporal dimensions
store_id - Store identifier
channel_group - Sales channel (Drive Thru, Takeout, Dine-In, Delivery/Online)
daypart - Time of day (Morning, Lunch, Afternoon, Dinner, Late Night)
day_of_week - Day of week
hour_of_day - Hour of day
menu_item_clean - Cleaned product name
report_group - Report group category
pop_channel - Specific POP channel
promo_category - Promotional category (Plain, Discounted)
Available Measures:
net_sales - Net sales revenue
gross_sales - Gross sales revenue
total_discount - Total discounts applied
check_count - Number of checks/transactions
item_count - Number of items
quantity - Quantity sold
tax - Tax amount
store_count - Store count
avg_ticket - Average ticket size
items_per_check - Items per check
discount_rate - Discount rate
-- Example: Daily sales by channel
SELECT 
  `date_clean`,
  `channel_group`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2025-04-01'
GROUP BY ALL
ORDER BY `date_clean`, `channel_group`;
3. Aggregated Tables

3.1 Store-Level Aggregates

Table: store_level_aggregates_store_agg
-- Example: Top stores by sales
SELECT 
  `store_id`,
  `net_sales`,
  `check_count`,
  `avg_ticket`,
  `discount_rate`,
  `channel_group`
FROM `store_level_aggregates_store_agg`
ORDER BY `net_sales` DESC
LIMIT 10;
3.2 Top Products

Table: top_15_items_by_net_sales_top_items
-- Example: Top 15 products
SELECT `item_name`, `net_sales`
FROM `top_15_items_by_net_sales_top_items`
ORDER BY `net_sales` DESC;
3.3 Year-over-Year Growth

Tables: report_group_growth__yoy__report_growth and item_growth__yoy__item_growth
-- Example: Growth by report group
SELECT 
  `report_group`,
  `growth_pct`,
  `sales_2025`,
  `sales_2026`
FROM `report_group_growth__yoy__report_growth`
ORDER BY `growth_pct` DESC;
3.4 Discount Analysis

Table: discounted_vs_plain_comparison_discount_compare
-- Example: Discounted vs plain comparison
SELECT 
  `promo_category`,
  `metric`,
  `value`
FROM `discounted_vs_plain_comparison_discount_compare`;
Common Use Cases

Monthly Trend Analysis

SELECT 
  `month`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`,
  MEASURE(`avg_ticket`) AS `avg_ticket`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
GROUP BY ALL
ORDER BY `month`;
Daypart Analysis

SELECT 
  `daypart`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2026-01-01'
GROUP BY ALL
ORDER BY `net_sales` DESC;
Channel Analysis by Hour

SELECT 
  `hour_of_day`,
  `channel_group`,
  MEASURE(`net_sales`) AS `net_sales`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01'
GROUP BY ALL
ORDER BY `hour_of_day`, `channel_group`;
Store Performance Comparison

SELECT 
  `store_id`,
  `net_sales`,
  `avg_ticket`,
  `discount_rate`
FROM `store_level_aggregates_store_agg`
WHERE `channel_group` = 'Drive Thru'
ORDER BY `net_sales` DESC;
Query Rules and Best Practices

# Metric View Syntax

The primary table is a Metric View and requires special syntax:
Use MEASURE() for all metrics
-- CORRECT
MEASURE(`net_sales`)

-- INCORRECT
`net_sales`
Always use GROUP BY ALL
SELECT `channel_group`, MEASURE(`net_sales`)
FROM ...
GROUP BY ALL  -- REQUIRED
**Never use SELECT ***
-- INCORRECT
SELECT * FROM ...

-- CORRECT
SELECT `store_id`, MEASURE(`net_sales`) FROM ...
Use backticks for all names
`date_clean`, `channel_group`, MEASURE(`net_sales`)
Efficient date filters
-- PREFERRED (allows pushdown optimization)
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2026-01-01'

-- AVOID (prevents pushdown)
WHERE YEAR(`date_clean`) = 2025
Use date_trunc() for temporal grouping
-- CORRECT
date_trunc('MONTH', `date_clean`) AS `month`

-- INCORRECT
YEAR(`date_clean`), MONTH(`date_clean`)
No nested aggregations on measures
-- INCORRECT
AVG(MEASURE(`net_sales`))
MAX(MEASURE(`net_sales`))

-- CORRECT: Use ORDER BY + LIMIT for max
SELECT MEASURE(`net_sales`) AS `net_sales`
FROM ...
GROUP BY ALL
ORDER BY `net_sales` DESC
LIMIT 1
Filter nulls in ORDER BY/GROUP BY
SELECT `channel_group`, MEASURE(`net_sales`)
FROM ...
WHERE `channel_group` IS NOT NULL
GROUP BY ALL
ORDER BY `net_sales` DESC;
Key Performance Indicators

The following KPIs are available in the dashboard:
Net Sales Revenue: Total net sales
Total Checks: Total number of transactions
Avg Ticket: Average transaction size
Items per Check: Average items per transaction
Discount Rate: Percentage of sales discounted
Active Stores: Number of active store locations
Data Coverage and Quality

Data Period: January 2025 through September 2026
Data Quality Metrics:
Raw records: 85.3M
Duplicate removal: 24% of raw data
Final clean records: 64.8M
Void transactions removed: 387K records
Granularity: Data available at daily level by store, product, channel, and hour
Date Format: Use 'YYYY-MM-DD' format for date filters
Performance Optimization Tips

Always filter by date range to reduce scan size
Use raw column filters instead of functions in WHERE clause
Aggregate before joining when combining with other tables
Limit result sets when exploring data
Use HAVING to filter on aggregated measures
Example of optimized query:
-- Efficient: filters on raw column, aggregates first
WITH store_metrics AS (
  SELECT 
    `store_id`,
    MEASURE(`net_sales`) AS `net_sales`,
    MEASURE(`check_count`) AS `check_count`
  FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
  WHERE `date_clean` >= '2025-01-01' 
    AND `date_clean` < '2026-01-01'
  GROUP BY ALL
)
SELECT * FROM store_metrics
WHERE `net_sales` > 100000
ORDER BY `net_sales` DESC;
Maintenance and Updates

To update or extend the pipeline:
Verify data quality in cleaning_pipeline_funnel_funnel
Validate new dimensions are available in primary metric view
Update aggregated tables as needed
Document any changes to metric definitions
Test queries against sample data before production deployment
Troubleshooting

# Common Issues:
Error: "Column not found"
Ensure backticks are used around all column names
Verify column exists in the schema
Error: "MEASURE() required"
Wrap all measure columns with MEASURE() function
Add GROUP BY ALL to query
Slow query performance
Add date range filter
Use raw column filters instead of functions
Consider pre-aggregated tables for common queries
Unexpected results
Verify date filters use correct format
Check for NULL values in dimensions
Validate GROUP BY includes all non-measure columns
Contact and Support

For questions about the pipeline or data access, contact the Taco Bueno Analytics team.
