# My-databricks-repository
Descripción General

Este pipeline de SQL analiza los datos de ventas de Taco Bueno, proporcionando métricas clave de rendimiento, análisis de descuentos, y tendencias de productos. Los datos están almacenados en Databricks y procesados a través de varias capas de agregación.
Arquitectura del Pipeline

1. Capa de Limpieza (Data Quality)

El pipeline comienza con un proceso de limpieza de datos documentado en cleaning_pipeline_funnel_funnel:
Raw ingest: 85,273,331 registros iniciales
After dedup: 65,149,963 registros (eliminación de duplicados ~24%)
After void removal: 64,762,862 registros finales
-- Ejemplo: Verificar funnel de limpieza
SELECT `stage`, `row_count`
FROM `cleaning_pipeline_funnel_funnel`
ORDER BY `stage_order`;
2. Vista Métrica Principal

Tabla: __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
Dimensiones disponibles:
date_clean, month - Dimensiones temporales
store_id - Identificador de tienda
channel_group - Canal de venta (Drive Thru, Takeout, Dine-In, Delivery/Online)
daypart - Parte del día (Morning, Lunch, Afternoon, Dinner, Late Night)
day_of_week - Día de la semana
hour_of_day - Hora del día
menu_item_clean - Producto limpio
report_group - Grupo de reporte
pop_channel - Canal POP específico
promo_category - Categoría promocional (Plain, Discounted)
Medidas disponibles:
net_sales - Ventas netas
gross_sales - Ventas brutas
total_discount - Descuentos totales
check_count - Número de checks
item_count - Número de items
quantity - Cantidad vendida
tax - Impuestos
store_count - Conteo de tiendas
avg_ticket - Ticket promedio
items_per_check - Items por check
discount_rate - Tasa de descuento
-- Ejemplo: Ventas diarias por canal
SELECT 
  `date_clean`,
  `channel_group`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2025-04-01'
GROUP BY ALL
ORDER BY `date_clean`, `channel_group`;
3. Tablas Agregadas

3.1 Agregados por Tienda

Tabla: store_level_aggregates_store_agg
-- Ejemplo: Top tiendas por ventas
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
3.2 Top Productos

Tabla: top_15_items_by_net_sales_top_items
-- Ejemplo: Top 15 productos
SELECT `item_name`, `net_sales`
FROM `top_15_items_by_net_sales_top_items`
ORDER BY `net_sales` DESC;
3.3 Crecimiento Year-over-Year

Tablas: report_group_growth__yoy__report_growth y item_growth__yoy__item_growth
-- Ejemplo: Crecimiento por grupo de reporte
SELECT 
  `report_group`,
  `growth_pct`,
  `sales_2025`,
  `sales_2026`
FROM `report_group_growth__yoy__report_growth`
ORDER BY `growth_pct` DESC;
3.4 Análisis de Descuentos

Tabla: discounted_vs_plain_comparison_discount_compare
-- Ejemplo: Comparación descuentos vs plain
SELECT 
  `promo_category`,
  `metric`,
  `value`
FROM `discounted_vs_plain_comparison_discount_compare`;
Casos de Uso Comunes

Análisis de Tendencias Mensuales

SELECT 
  `month`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`,
  MEASURE(`avg_ticket`) AS `avg_ticket`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
GROUP BY ALL
ORDER BY `month`;
Análisis por Daypart

SELECT 
  `daypart`,
  MEASURE(`net_sales`) AS `net_sales`,
  MEASURE(`check_count`) AS `check_count`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2026-01-01'
GROUP BY ALL
ORDER BY `net_sales` DESC;
Análisis de Canales por Hora

SELECT 
  `hour_of_day`,
  `channel_group`,
  MEASURE(`net_sales`) AS `net_sales`
FROM __databricks_internal_catalog_lakeview_7474648175062287.01f1c2893ad210659d9a2529b0ec3374_f3f965bd.lakegenie_01f1c28b1a891f68b2a13c39fc6aeda3
WHERE `date_clean` >= '2025-01-01'
GROUP BY ALL
ORDER BY `hour_of_day`, `channel_group`;
Reglas Importantes para Queries

Vista Métrica (Metric View)

Esta tabla es una Metric View y requiere sintaxis especial:
Usar MEASURE() para todas las métricas
-- CORRECTO
MEASURE(`net_sales`)

-- INCORRECTO
`net_sales`
Siempre usar GROUP BY ALL
SELECT `channel_group`, MEASURE(`net_sales`)
FROM ...
GROUP BY ALL  -- REQUERIDO
Nunca usar SELECT *
-- INCORRECTO
SELECT * FROM ...

-- CORRECTO
SELECT `store_id`, MEASURE(`net_sales`) FROM ...
Usar backticks para todos los nombres
`date_clean`, `channel_group`, MEASURE(`net_sales`)
Filtros de fecha eficientes
-- PREFERIDO (permite pushdown)
WHERE `date_clean` >= '2025-01-01' AND `date_clean` < '2026-01-01'

-- EVITAR (no permite pushdown)
WHERE YEAR(`date_clean`) = 2025
Usar date_trunc() para agrupación temporal
-- CORRECTO
date_trunc('MONTH', `date_clean`) AS `month`

-- INCORRECTO
YEAR(`date_clean`), MONTH(`date_clean`)
Métricas KPI Principales

Las siguientes métricas están disponibles en el dashboard:
Net Sales Revenue: Total de ventas netas
Total Checks: Número total de transacciones
Avg Ticket: Ticket promedio por transacción
Items per Check: Promedio de items por check
Discount Rate: Tasa de descuento aplicada
Active Stores: Número de tiendas activas
Notas Técnicas

Período de datos: Los datos cubren desde enero 2025 hasta septiembre 2026
Limpieza de datos: ~24% de registros fueron duplicados y removidos
Granularidad: Los datos están disponibles a nivel diario, por tienda, producto, canal y hora
Formato de fechas: Usar formato 'YYYY-MM-DD' para filtros de fecha
Mantenimiento y Actualizaciones

Para actualizar o extender el pipeline:
Verificar la calidad de datos en cleaning_pipeline_funnel_funnel
Validar que las nuevas dimensiones estén disponibles en la vista métrica principal
Actualizar tablas agregadas según sea necesario
Documentar cualquier cambio en las definiciones de métricas
Contacto y Soporte

Para preguntas sobre el pipeline o acceso a los datos, contactar al equipo de Analytics de Taco Bueno.
