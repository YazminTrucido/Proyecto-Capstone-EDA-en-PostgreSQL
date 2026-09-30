-- =============================================================================
-- analisis.sql  ·  Capstone Project
-- =============================================================================

-- =============================================================================
-- A. AUDITORÍA DE DATOS
-- =============================================================================

-- A1. Profiling de nulos pre-ETL
WITH conteo AS (
    SELECT COUNT(*)                                     AS total,
           COUNT(NULLIF(TRIM(order_id), ''))            AS c_order_id,
           COUNT(NULLIF(TRIM(order_date_time), ''))     AS c_fecha_pedido,
           COUNT(NULLIF(TRIM(item_price), ''))          AS c_precio,
           COUNT(NULLIF(TRIM(product_category), ''))    AS c_categoria_producto,
           COUNT(NULLIF(TRIM(customer_city), ''))       AS c_ciudad,
           COUNT(NULLIF(TRIM(connected_handling_time), '')) AS c_tiempo_atencion,
           COUNT(NULLIF(TRIM(customer_remarks), ''))    AS c_comentario
    FROM stg_soporte
)
SELECT v.columna,
       c.total - v.no_nulos                                   AS nulos,
       ROUND(100.0 * (c.total - v.no_nulos) / c.total, 1)     AS pct_nulos
FROM conteo c
CROSS JOIN LATERAL (VALUES
    ('order_id',                c.c_order_id),
    ('order_date_time',         c.c_fecha_pedido),
    ('item_price',              c.c_precio),
    ('product_category',        c.c_categoria_producto),
    ('customer_city',           c.c_ciudad),
    ('connected_handling_time', c.c_tiempo_atencion),
    ('customer_remarks',        c.c_comentario)
) AS v (columna, no_nulos)
ORDER BY pct_nulos DESC;

-- A2. Detección de anomalías mitigadas
SELECT 'Respuesta anterior al reporte (tiempo negativo)' AS anomalia,
       COUNT(*) AS filas
FROM tickets
WHERE fecha_respuesta < fecha_reporte
UNION ALL
SELECT 'Pedido fechado DESPUÉS del ticket',
       COUNT(*)
FROM tickets t
JOIN pedidos p ON p.order_id = t.order_id
WHERE p.fecha_pedido > t.fecha_reporte
UNION ALL
SELECT 'Precio = 0 en origen (convertido a NULL)',
       COUNT(*)
FROM stg_soporte
WHERE NULLIF(TRIM(item_price), '')::NUMERIC = 0
UNION ALL
SELECT 'Pedidos con solo ID (sin precio ni fecha)',
       COUNT(*)
FROM pedidos
WHERE precio_item IS NULL AND fecha_pedido IS NULL;

-- A3. Métricas base (KPIs)
SELECT COUNT(*)                                                                    AS tickets,
       ROUND(AVG(csat), 2)                                                         AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN csat >= 4 THEN 1 ELSE 0 END) / COUNT(*), 1)     AS pct_satisfechos,
       ROUND(100.0 * SUM(CASE WHEN csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1)     AS pct_insatisfechos,
       ROUND(100.0 * COUNT(order_id) / COUNT(*), 1)                                AS pct_con_pedido,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tiempo_respuesta_min))::NUMERIC, 1) AS mediana_respuesta_min
FROM tickets;


-- =============================================================================
-- B. ANÁLISIS DE VENTAS Y PERFILADO
-- =============================================================================

-- B1. Ventas afectadas por volumen de soporte (mensual)
-- Filtro pedidos posteriores al ticket para sanear cronología
WITH ventas_mensuales AS (
    SELECT DATE_TRUNC('month', p.fecha_pedido)::DATE AS mes,
           COUNT(*)                                  AS pedidos,
           COALESCE(SUM(p.precio_item), 0)           AS ventas
    FROM pedidos p
    JOIN tickets t ON t.order_id = p.order_id
    WHERE p.fecha_pedido IS NOT NULL          
      AND p.precio_item  IS NOT NULL          
      AND p.fecha_pedido <= t.fecha_reporte
    GROUP BY 1
)
SELECT mes,
       pedidos,
       ventas,
       ROUND(100.0 * pedidos / SUM(pedidos) OVER (), 1) AS pct_de_los_pedidos,
       ROUND(100.0 * (ventas - LAG(ventas) OVER (ORDER BY mes))
                   / NULLIF(LAG(ventas) OVER (ORDER BY mes), 0), 1) AS var_pct_vs_mes_anterior
FROM ventas_mensuales
ORDER BY mes;

-- B2. Top 5 clústers geográficos por gasto retenido
SELECT COALESCE(p.ciudad_cliente, 'Sin dato')                               AS ciudad,
       COUNT(*)                                                             AS pedidos,
       SUM(p.precio_item)                                                   AS gasto_total,
       ROUND(AVG(p.precio_item), 0)                                         AS ticket_promedio,
       ROUND(100.0 * SUM(p.precio_item) / SUM(SUM(p.precio_item)) OVER (), 2) AS pct_del_gasto_total,
       ROUND(AVG(t.csat), 2)                                                AS csat_promedio
FROM pedidos p
JOIN tickets t ON t.order_id = p.order_id
WHERE p.precio_item IS NOT NULL
GROUP BY COALESCE(p.ciudad_cliente, 'Sin dato')
ORDER BY gasto_total DESC
LIMIT 5;

-- B3. Categorías con menor rotación de tickets
SELECT p.categoria_producto,
       COUNT(*)                          AS pedidos,
       COALESCE(SUM(p.precio_item), 0)   AS ventas,
       ROUND(AVG(p.precio_item), 0)      AS precio_promedio,
       ROUND(100.0 * SUM(p.precio_item) / SUM(SUM(p.precio_item)) OVER (), 1) AS pct_de_las_ventas
FROM pedidos p
WHERE p.categoria_producto IS NOT NULL
GROUP BY p.categoria_producto
ORDER BY pedidos ASC, p.categoria_producto
LIMIT 3;

-- B4. High-value orders ranking por categoría
WITH pedidos_rankeados AS (
    SELECT p.order_id,
           p.categoria_producto,
           p.ciudad_cliente,
           p.precio_item,
           RANK() OVER (PARTITION BY p.categoria_producto
                        ORDER BY p.precio_item DESC) AS ranking
    FROM pedidos p
    WHERE p.categoria_producto IS NOT NULL
      AND p.precio_item IS NOT NULL
)
SELECT r.categoria_producto,
       r.ranking,
       r.precio_item,
       COALESCE(r.ciudad_cliente, 'Sin dato') AS ciudad,
       c.nombre                               AS motivo_contacto
FROM pedidos_rankeados r
JOIN tickets       t  ON t.order_id = r.order_id
JOIN subcategorias sc ON sc.subcategoria_id = t.subcategoria_id
JOIN categorias    c  ON c.categoria_id = sc.categoria_id
WHERE r.ranking <= 3
ORDER BY r.categoria_producto, r.ranking, r.order_id;


-- =============================================================================
-- C. CALIDAD OPERATIVA Y CSAT
-- =============================================================================

-- C1. Drivers de contacto
SELECT c.nombre                                                                AS motivo_contacto,
       COUNT(*)                                                                AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS pct_del_volumen,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos,
       COUNT(p.precio_item)                                                    AS pedidos_valorizados,
       COALESCE(SUM(p.precio_item), 0)                                         AS valor_pedidos_en_juego
FROM tickets t
JOIN subcategorias sc ON sc.subcategoria_id = t.subcategoria_id
JOIN categorias    c  ON c.categoria_id = sc.categoria_id
LEFT JOIN pedidos  p  ON p.order_id = t.order_id
GROUP BY c.nombre
ORDER BY pct_insatisfechos DESC, tickets DESC;

-- C2. Pain points granulares (filtro estadístico n>=200)
SELECT c.nombre                                                                AS motivo_contacto,
       sc.nombre                                                               AS subcategoria,
       COUNT(*)                                                                AS tickets,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos
FROM tickets t
JOIN subcategorias sc ON sc.subcategoria_id = t.subcategoria_id
JOIN categorias    c  ON c.categoria_id = sc.categoria_id
GROUP BY c.nombre, sc.nombre
HAVING COUNT(*) >= 200
ORDER BY pct_insatisfechos DESC, tickets DESC
LIMIT 5;

-- C3. Sensibilidad del CSAT ante SLAs
SELECT CASE
           WHEN t.tiempo_respuesta_min IS NULL THEN '6. Sin dato (fechas inconsistentes)'
           WHEN t.tiempo_respuesta_min <= 5    THEN '1. Hasta 5 min'
           WHEN t.tiempo_respuesta_min <= 30   THEN '2. 5 a 30 min'
           WHEN t.tiempo_respuesta_min <= 60   THEN '3. 30 a 60 min'
           WHEN t.tiempo_respuesta_min <= 240  THEN '4. 1 a 4 horas'
           ELSE                                     '5. Más de 4 horas'
       END                                                                     AS rango_respuesta,
       COUNT(*)                                                                AS tickets,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos
FROM tickets t
GROUP BY 1
ORDER BY 1;

-- C4. Impacto del seniority operativo
SELECT a.antiguedad,
       COUNT(DISTINCT a.agente_id)                                             AS agentes,
       COUNT(*)                                                                AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS pct_de_los_tickets,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.tiempo_respuesta_min))::NUMERIC, 1) AS mediana_respuesta_min
FROM tickets t
JOIN agentes a ON a.agente_id = t.agente_id
GROUP BY a.antiguedad
ORDER BY CASE a.antiguedad
             WHEN 'On Job Training' THEN 1
             WHEN '0-30'            THEN 2
             WHEN '31-60'           THEN 3
             WHEN '61-90'           THEN 4
             ELSE                        5
         END;

-- C5. Rendimiento por canal de atención
SELECT t.canal,
       COUNT(*)                                                                AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS pct_del_volumen,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.tiempo_respuesta_min))::NUMERIC, 1) AS mediana_respuesta_min
FROM tickets t
GROUP BY t.canal
ORDER BY pct_insatisfechos DESC;
