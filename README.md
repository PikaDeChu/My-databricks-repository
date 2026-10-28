Our pipeline is designed to process Taco Bueno’s sales data and transform it into useful information for analysis.

To achieve this, we use three layers:

1. Bronze: This is the first stage. It automatically reads CSV files and stores the original data in Databricks without changing its content.

2. Silver: In this stage, we clean and organize the data. We correct data types, identify invalid values, remove duplicate records, and apply validations to improve data quality.

3. Gold: Finally, we transform the cleaned data into business metrics. We create six tables that allow us to analyze daily sales, best-selling products, store performance, and discounts.

In conclusion, our pipeline automates CSV data processing and provides organized, reliable information to help us understand Taco Bueno’s sales performance.
