-- =============================================================================
-- analisis.sql  ·  Proyecto Capstone SQL (PostgreSQL)
-- Requisito previo: haber ejecutado estructura.sql y cargado el CSV.
--
-- Pregunta de negocio: ¿dónde se pierde calidad en la atención de soporte de un
-- e-commerce y qué palancas operativas la mejoran?
--
-- Definiciones usadas en todo el archivo:
--   * Cliente satisfecho   = CSAT 4 o 5      * Cliente insatisfecho = CSAT 1 o 2
--   * "Ventas"             = precio_item de los pedidos QUE GENERARON un ticket.
--                            No son las ventas totales de la empresa.
--   * Los NULL de precio/fecha no se reemplazan por 0: se excluyen del cálculo y se
--     cuantifican. COALESCE se usa para etiquetas ('Sin dato') y totales.
--
-- Índice:
--   A. Calidad de datos  A1 nulos · A2 anomalías · A3 tipos · A4 línea base (KPIs)
--   B. Ventas            1 ventas por mes · 2 top 5 ciudades · 3 categorías menos
--                        vendidas · 4 ranking de pedidos por categoría (RANK)
--   C. Experiencia       5 motivos de contacto · 6 subcategorías críticas ·
--                        7 tiempo de respuesta vs CSAT · 8 antigüedad de agentes · 9 canal
-- =============================================================================


-- #############################################################################
-- A. CALIDAD DE DATOS  (etapa previa al análisis final)
-- #############################################################################

-- A1. ¿Cuánta información falta en cada columna crítica del CSV original?
-- Se mide sobre staging (datos crudos) para documentar el problema ANTES de limpiar.
-- COUNT(columna) ignora NULL; NULLIF(TRIM(x), '') trata además las celdas vacías como ausentes.
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
-- LECTURA: precio, fecha de pedido, ciudad y categoría de producto faltan en ~80 % de
-- los tickets; connected_handling_time en 99,7 %. Solo ~1 de cada 5 tickets trae datos
-- de la compra. Por eso las conclusiones sobre ventas (parte B) describen esa minoría
-- y no se extrapolan a toda la operación; y por eso la columna de tiempo de atención
-- se descarta del análisis.


-- A2. Datos imposibles o incoherentes que la limpieza neutralizó.
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
-- LECTURA: 3.128 tickets (3,6 %) tienen la respuesta "antes" del reporte: sus tiempos se
-- anularon en vez de promediarlos, porque un tiempo negativo distorsiona cualquier promedio.
-- 58 pedidos figuran comprados después del ticket y se excluyen de la serie mensual.


-- A3. Verificación de tipos de datos (DATE/TIMESTAMP para fechas, NUMERIC para montos).
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('tickets', 'pedidos')
  AND column_name IN ('fecha_pedido', 'fecha_reporte', 'fecha_respuesta', 'fecha_encuesta',
                      'precio_item', 'tiempo_respuesta_min', 'csat')
ORDER BY table_name, column_name;


-- A4. Línea base: los KPIs contra los que se comparan todos los análisis siguientes.
-- CASE dentro de SUM convierte una condición en un conteo (1 si cumple, 0 si no).
SELECT COUNT(*)                                                                    AS tickets,
       ROUND(AVG(csat), 2)                                                         AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN csat >= 4 THEN 1 ELSE 0 END) / COUNT(*), 1)     AS pct_satisfechos,
       ROUND(100.0 * SUM(CASE WHEN csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1)     AS pct_insatisfechos,
       ROUND(100.0 * COUNT(order_id) / COUNT(*), 1)                                AS pct_con_pedido,
       -- mediana y no promedio: hay respuestas de días que inflan la media (~176 min vs mediana 6)
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tiempo_respuesta_min))::NUMERIC, 1) AS mediana_respuesta_min
FROM tickets;
-- LECTURA: 85.907 tickets, CSAT 4,24 sobre 5; 82,5 % satisfechos y 14,6 % insatisfechos.
-- La mediana de respuesta es de 6 minutos: la operación es rápida en general, y el
-- problema está en la "cola" de casos lentos (ver consulta 7).


-- #############################################################################
-- B. VENTAS
-- #############################################################################

-- 1. Ventas totales por mes (funciones de fecha + CTE + LAG).
-- JOIN con tickets para descartar pedidos fechados después del ticket (error de origen, ver A2).
-- order_id es único por ticket, así que el JOIN es 1 a 1 y no duplica ventas.
-- LAG compara cada mes con el anterior sin perder el detalle de cada fila.
WITH ventas_mensuales AS (
    SELECT DATE_TRUNC('month', p.fecha_pedido)::DATE AS mes,
           COUNT(*)                                  AS pedidos,
           COALESCE(SUM(p.precio_item), 0)           AS ventas
    FROM pedidos p
    JOIN tickets t ON t.order_id = p.order_id
    WHERE p.fecha_pedido IS NOT NULL          -- sin fecha no se puede asignar a un mes
      AND p.precio_item  IS NOT NULL          -- sin precio no hay venta que sumar
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
-- LECTURA: julio y agosto de 2023 concentran casi el 95 % de los pedidos (4.957 y 11.308) y
-- ~94 % de las ventas; los 18 meses anteriores (ene-2022 a jun-2023) suman ~5 % de los pedidos
-- y ~6 % de las ventas. NO es crecimiento de ventas:
-- los tickets se abrieron entre el 28/07 y el 31/08/2023, y la gente reclama sobre compras
-- recientes. Conclusión útil para el negocio: la demanda de soporte sigue a las ventas de las
-- últimas semanas, por lo que conviene dimensionar el equipo con un horizonte de 4 a 6 semanas.


-- 2. Top 5 ciudades por gasto total (GROUP BY + SUM).
-- La base no trae ID de cliente: la ciudad es la unidad geográfica más fina disponible.
-- COALESCE evita un grupo NULL sin nombre (135 pedidos valorizados no traen ciudad).
-- SUM(SUM(...)) OVER () calcula el total general para expresar cada ciudad como % del total.
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
-- LECTURA: Hyderabad (6,1 M; 6,3 %), New Delhi, Mumbai, Pune y Bangalore encabezan el gasto, pero
-- entre las 5 suman solo 20,3 % del total repartido en 1.782 ciudades: la base de clientes está
-- muy atomizada y no hay una plaza que justifique una estrategia de soporte exclusiva.
-- Dato accionable: el CSAT de esas ciudades (3,60 a 3,85) está BAJO el promedio general (4,24).
-- Los clientes con pedidos de alto valor que contactan a soporte están menos conformes que el resto.


-- 3. Las 3 categorías de producto menos vendidas (COUNT + ORDER BY + LIMIT).
-- "Vendido" = pedido que generó un ticket (no hay catálogo ni tabla de ventas completa).
-- Desempate por nombre para que el resultado sea siempre el mismo.
-- El % de ventas se calcula sobre TODAS las categorías (la ventana se evalúa antes del LIMIT);
-- sacá el LIMIT para ver el ranking completo, incluido Mobile.
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
-- LECTURA: GiftCard (26), Affiliates (166) y Furniture (471). "Menos vendido" no es "menos importante":
-- Furniture mueve ~4 M (4,1 % de las ventas) con solo 471 pedidos porque es de ticket alto
-- (precio promedio ~8.500), mientras Affiliates casi no factura (precio promedio ~214). En el otro
-- extremo, Mobile es ~10 % de los pedidos pero ~42 % de las ventas: los recursos deberían priorizar
-- el valor y no solo el volumen.


-- 4. Ranking de pedidos por categoría de producto con RANK() (Window Function).
-- PARTITION BY reinicia el ranking dentro de cada categoría; RANK() (no ROW_NUMBER) deja
-- empates con el mismo puesto, por eso algunas categorías muestran más de 3 filas.
-- Se hace en un CTE porque no se puede filtrar por ranking <= 3 en el mismo SELECT que lo calcula.
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
-- LECTURA: el pedido más caro de la base es un Mobile de 164.999 (motivo 'Order Related') y en
-- Electronics de 159.990 (motivo 'Returns'). De los 29 pedidos del top 3 por categoría, 21 (72 %) llegan
-- por 'Returns' u 'Order Related', casi el mismo peso que esos motivos tienen en toda la base (78 %).
-- Es decir, los pedidos caros no generan problemas distintos: hay que reforzar la misma gestión
-- de devoluciones y pedidos, con seguimiento prioritario de los casos de mayor valor.


-- #############################################################################
-- C. EXPERIENCIA DEL CLIENTE
-- #############################################################################

-- 5. Motivos de contacto: volumen, satisfacción y valor de pedidos en juego.
-- LEFT JOIN a pedidos: con INNER JOIN se perderían los tickets sin pedido asociado (21 % del total)
-- y se sesgaría el CSAT. COUNT(p.precio_item) cuenta solo los pedidos con precio informado.
-- COALESCE(SUM(...), 0): si una categoría no tiene ningún pedido valorizado, SUM da NULL y se muestra 0.
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
-- LECTURA: Returns (51,3 %) y Order Related (27,0 %) son el 78 % de todo el soporte: ahí está el volumen
-- y el dinero (Order Related concentra ~49 M de pedidos valorizados y Returns ~30 M). Returns se atiende
-- bien (12,2 % de insatisfechos); Order Related está en 17,9 %, por encima del 14,6 % promedio.
-- Las peores tasas son Cancellation (21,5 %, 2.212 tickets) y 'Others' (33,3 %, pero solo 99 tickets).
-- App/website y Onboarding muestran 0 en valor en juego porque ningún ticket trae precio, no porque valgan 0.


-- 6. Subcategorías críticas: dónde nace la insatisfacción.
-- HAVING filtra sobre el resultado agregado (WHERE no puede usar COUNT): pedimos al menos
-- 200 tickets para no sacar conclusiones con muestras chicas.
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
ORDER BY pct_insatisfechos DESC, tickets DESC   -- el desempate por volumen evita empates al redondear
LIMIT 5;
-- LECTURA: Returns / Technician Visit (33,6 % insatisfechos) y Order Related / Seller Cancelled Order
-- (30,4 %, 1.059 tickets) son los dos puntos más dolorosos: ambos son fallos de cumplimiento (la visita
-- técnica o el vendedor no cumplen), no de atención. Un agente no puede compensarlos.
-- Por volumen pesa más Order Related / Delayed: 7.388 tickets (8,6 % del total) con 19,8 % de insatisfechos.
-- Contrasta con Returns / Return request (8.523 tickets, 5,5 % insatisfechos, fuera del top porque
-- funciona bien): el proceso estándar de devolución está resuelto; los problemas están en las excepciones.


-- 7. Tiempo de respuesta vs satisfacción (CASE para armar rangos).
-- Los números iniciales ('1.', '2.', ...) fuerzan el orden correcto al ordenar por texto.
-- Los tickets con tiempo NULL (fechas inconsistentes, ver A2) quedan en su propio rango
-- en lugar de desaparecer del conteo.
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
-- LECTURA: la satisfacción cae de forma escalonada con la espera. Hasta 5 min: CSAT 4,48 y 8,9 % de
-- insatisfechos; más de 4 horas: CSAT 3,71 y 27,7 % (más del triple). El 12,9 % de los tickets con tiempo
-- válido (10.660) espera más de 4 horas. Es una asociación, no prueba causalidad (los casos más
-- complejos también tardan más), pero es la palanca operativa más clara: atacar la cola de casos lentos
-- (alertas de SLA a los 30 minutos, derivación automática a supervisores) rinde más que acelerar los rápidos.
-- Los 3.128 tickets con fechas inconsistentes tienen CSAT 4,39 (10,8 % insatisfechos): no empeoran
-- el cuadro, así que anular sus tiempos no sesga la conclusión.


-- 8. Antigüedad del agente vs satisfacción (JOIN con agentes).
-- Mediana de respuesta y no promedio: algunos tickets tardan días y distorsionan la media.
-- El CASE del ORDER BY ordena las franjas de forma lógica (alfabético pondría '>90' primero).
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
-- LECTURA: los agentes en entrenamiento (On Job Training) son 518 de 1.371 (38 %), atienden el 29,7 %
-- de los tickets y tienen la peor satisfacción: CSAT 4,15 y 16,6 % de insatisfechos, contra 12,2 % a 14,1 % del resto. La mejor
-- franja es 61-90 días (4,35), y >90 días (4,27) no mejora a los de 31-60: la experiencia por sí sola
-- no explica el CSAT. Recomendación: acompañar/derivar a los agentes en entrenamiento en los motivos
-- críticos de la consulta 6 (Technician Visit, Seller Cancelled Order, Cancellations).


-- 9. Canal de contacto vs satisfacción.
-- Sin JOIN: el canal es un atributo del propio ticket.
SELECT t.canal,
       COUNT(*)                                                                AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS pct_del_volumen,
       ROUND(AVG(t.csat), 2)                                                   AS csat_promedio,
       ROUND(100.0 * SUM(CASE WHEN t.csat <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_insatisfechos,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.tiempo_respuesta_min))::NUMERIC, 1) AS mediana_respuesta_min
FROM tickets t
GROUP BY t.canal
ORDER BY pct_insatisfechos DESC;
-- LECTURA: Email es el canal más débil: CSAT 3,90 y 23,2 % de insatisfechos contra ~14 % en Inbound
-- y Outcall, aunque solo aporta el 3,5 % del volumen. Parte de la brecha puede venir del tipo de
-- consultas (en Email pesan más Refund Related y Order Related), pero la mediana de respuesta
-- (7 min) no explica por sí sola el problema: conviene revisar la calidad de las respuestas por escrito.
