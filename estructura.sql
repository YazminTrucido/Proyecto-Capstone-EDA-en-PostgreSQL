-- =============================================================================
-- estructura.sql  ·  Proyecto Capstone SQL (PostgreSQL)
-- Tema    : Calidad de la atención de soporte al cliente de un e-commerce (CSAT)
-- Dataset : Customer_support_data.csv (85.907 tickets, 20 columnas, jul-ago 2023)
-- Contenido:
--   1. Reinicio del modelo limpio (el script se puede ejecutar varias veces)
--   2. Tabla de staging con el CSV "en crudo"
--   3. Carga del CSV (instrucciones)
--   4. Modelo limpio: categorias, subcategorias, agentes, pedidos, tickets
--   5. Limpieza y transformación: staging -> modelo limpio
--   6. Índices
--   7. Verificación de la carga
-- =============================================================================

-- PASO 0 (una sola vez, conectado a la base 'postgres'; no va dentro de este archivo
-- porque CREATE DATABASE no se puede combinar con el resto en la misma sesión):
--     CREATE DATABASE capstone_project;
-- Después conectate a capstone_project y ejecutá este archivo.


-- =============================================================================
-- 1. REINICIO DEL MODELO LIMPIO
-- Borramos solo las tablas limpias. La de staging se conserva para no tener que
-- volver a cargar el CSV cada vez que re-ejecutamos el script.
-- =============================================================================
DROP TABLE IF EXISTS tickets, pedidos, agentes, subcategorias, categorias CASCADE;


-- =============================================================================
-- 2. STAGING (datos crudos)
-- Todo es TEXT a propósito: el CSV trae fechas en dos formatos distintos, celdas
-- vacías y números como texto. Si tipáramos al cargar, una sola fila "rara"
-- haría fallar la importación completa. Tipamos recién en el paso 5, donde
-- podemos controlar cada conversión.
-- El orden de las columnas es el MISMO que el del CSV (el COPY mapea por posición).
-- =============================================================================
CREATE TABLE IF NOT EXISTS stg_soporte (
    unique_id               TEXT,   -- "Unique id": identifica cada ticket
    channel_name            TEXT,   -- Inbound / Outcall / Email
    category                TEXT,   -- motivo general del contacto
    sub_category            TEXT,   -- "Sub-category": motivo específico
    customer_remarks        TEXT,   -- comentario libre del cliente (66 % vacío)
    order_id                TEXT,   -- pedido asociado al ticket (21 % vacío)
    order_date_time         TEXT,   -- 'DD/MM/YYYY HH24:MI'
    issue_reported_at       TEXT,   -- "Issue_reported at": 'DD/MM/YYYY HH24:MI'
    issue_responded         TEXT,   -- 'DD/MM/YYYY HH24:MI'
    survey_response_date    TEXT,   -- 'DD-Mon-YY' (formato distinto a las otras fechas)
    customer_city           TEXT,   -- viene en MAYÚSCULAS (80 % vacío)
    product_category        TEXT,   -- (80 % vacío)
    item_price              TEXT,   -- (80 % vacío)
    connected_handling_time TEXT,   -- (99,7 % vacío)
    agent_name              TEXT,
    supervisor              TEXT,
    manager                 TEXT,
    tenure_bucket           TEXT,   -- "Tenure Bucket": antigüedad del agente
    agent_shift             TEXT,   -- "Agent Shift": turno del agente
    csat_score              TEXT    -- "CSAT Score": 1 a 5
);


-- =============================================================================
-- 3. CARGA DEL CSV EN stg_soporte  (elegí UNA opción)
-- =============================================================================
-- Opción A — psql (recomendada). Ejecutar desde la carpeta raíz del repo, con el
--            CSV en data/Customer_support_data.csv. \copy es un comando de psql,
--            por eso va en UNA sola línea y NO funciona en el Query Tool de pgAdmin:
--
--   \copy stg_soporte FROM 'data/Customer_support_data.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
--
-- Opción B — pgAdmin 4: clic derecho sobre stg_soporte > Import/Export Data...
--            Import | Format: csv | Header: Yes | Delimiter: "," | Encoding: UTF8.
--
-- Opción C — COPY del servidor (necesita que el archivo esté en el servidor y
--            permisos de superusuario o pg_read_server_files):
--
--   COPY stg_soporte FROM '/ruta/absoluta/Customer_support_data.csv' WITH (FORMAT csv, HEADER true);
--
-- Si ya cargaste datos y querés recargar desde cero: TRUNCATE stg_soporte;
-- Flujo: 1) ejecutar este archivo (crea todo) -> 2) cargar el CSV -> 3) volver a
-- ejecutar este archivo (los pasos 4 a 7 ahora sí encuentran datos).


-- =============================================================================
-- 4. MODELO LIMPIO
-- Normalizamos el CSV (una "hoja gigante" de 20 columnas) en 5 tablas para evitar
-- redundancia: el nombre de una categoría o los datos de un agente se repetían
-- miles de veces.
--
--   categorias 1──N subcategorias 1──N tickets N──1 agentes
--                                      tickets N──1 pedidos (opcional)
--
-- Nota de diseño: el dataset NO trae ID de cliente ni catálogo de productos.
-- "Cliente" se aproxima con la ciudad y "producto" con la categoría de producto,
-- ambos atributos de la tabla pedidos.
-- =============================================================================

CREATE TABLE categorias (
    categoria_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(40) NOT NULL UNIQUE
);

-- 'General Enquiry' aparece bajo 3 categorías distintas, por eso la unicidad es
-- sobre el par (categoria_id, nombre) y no sobre el nombre solo.
CREATE TABLE subcategorias (
    subcategoria_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    categoria_id    SMALLINT    NOT NULL REFERENCES categorias (categoria_id),
    nombre          VARCHAR(60) NOT NULL,
    UNIQUE (categoria_id, nombre)
);

-- Supervisor y manager quedan como atributos del agente y no como tablas propias:
-- en los datos un mismo nombre de supervisor aparece bajo varios managers, así que
-- no hay una jerarquía limpia que modelar. Cada agente tiene un único supervisor,
-- manager, antigüedad y turno (verificado antes de normalizar).
CREATE TABLE agentes (
    agente_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre     VARCHAR(60) NOT NULL UNIQUE,
    supervisor VARCHAR(60) NOT NULL,
    manager    VARCHAR(60) NOT NULL,
    antiguedad VARCHAR(20) NOT NULL,   -- 'On Job Training', '0-30', '31-60', '61-90', '>90' (días)
    turno      VARCHAR(20) NOT NULL    -- Morning, Afternoon, Evening, Night, Split
);

-- Un pedido solo existe en esta base si generó al menos un ticket.
-- Precio, fecha, ciudad y categoría de producto son NULL en ~75 % de los pedidos
-- porque el dataset original no los informa; no se inventan valores.
CREATE TABLE pedidos (
    order_id           UUID PRIMARY KEY,
    fecha_pedido       TIMESTAMP,
    ciudad_cliente     VARCHAR(60),
    categoria_producto VARCHAR(40),
    precio_item        NUMERIC(12, 2) CHECK (precio_item > 0)  -- un precio 0 es un dato erróneo, no una venta
);

CREATE TABLE tickets (
    ticket_id            UUID PRIMARY KEY,
    canal                VARCHAR(20) NOT NULL,                        -- Inbound / Outcall / Email
    subcategoria_id      SMALLINT    NOT NULL REFERENCES subcategorias (subcategoria_id),
    order_id             UUID        REFERENCES pedidos (order_id),   -- NULL: contacto sin pedido asociado
    agente_id            INTEGER     NOT NULL REFERENCES agentes (agente_id),
    fecha_reporte        TIMESTAMP   NOT NULL,
    fecha_respuesta      TIMESTAMP   NOT NULL,
    fecha_encuesta       DATE        NOT NULL,
    tiempo_respuesta_min NUMERIC(8, 1),                               -- NULL si la respuesta figura ANTES del reporte (error de origen)
    tiempo_atencion      INTEGER,                                     -- "connected_handling_time": unidad no documentada, 99,7 % NULL; no se usa en el análisis
    csat                 SMALLINT    NOT NULL CHECK (csat BETWEEN 1 AND 5),
    comentario           TEXT
);


-- =============================================================================
-- 5. LIMPIEZA Y TRANSFORMACIÓN  (staging -> modelo limpio)
-- Reglas aplicadas y por qué:
--   * TRIM en todo el texto: evita que 'Mobile ' y 'Mobile' cuenten como categorías distintas.
--   * Celdas vacías -> NULL (NULLIF(..., '')): un vacío no es un dato, es una ausencia.
--   * Fechas con formato explícito en TO_TIMESTAMP/TO_DATE: '01/08/2023' es 1 de agosto
--     (día primero); si dejáramos que Postgres adivine podría leerlo como 8 de enero.
--   * Precio 0 -> NULL: hay 1 pedido con precio 0; contarlo como 0 bajaría los promedios.
--   * Los NULL de precio/fecha NO se reemplazan por 0 ni por fechas inventadas:
--     se excluyen del cálculo y se cuantifican (ver analisis.sql, parte A).
--     COALESCE se usa en el análisis para etiquetas y totales.
--   * Respuesta anterior al reporte (3.128 tickets, tiempo negativo imposible)
--     -> tiempo_respuesta_min = NULL, pero se conservan ambas fechas originales.
--   * Ciudad: INITCAP('NEW DELHI') = 'New Delhi' para unificar el formato.
-- =============================================================================

-- Vaciamos las tablas limpias antes de insertar (por si se re-ejecuta solo este bloque).
TRUNCATE tickets, pedidos, agentes, subcategorias, categorias RESTART IDENTITY CASCADE;

INSERT INTO categorias (nombre)
SELECT DISTINCT TRIM(category)
FROM stg_soporte
ORDER BY 1;

INSERT INTO subcategorias (categoria_id, nombre)
SELECT DISTINCT c.categoria_id, TRIM(s.sub_category)
FROM stg_soporte s
JOIN categorias c ON c.nombre = TRIM(s.category)
ORDER BY 1, 2;

-- Suponemos que el nombre identifica al agente (1.371 nombres). La restricción
-- UNIQUE(nombre) haría fallar este INSERT si un mismo nombre tuviera dos perfiles distintos.
INSERT INTO agentes (nombre, supervisor, manager, antiguedad, turno)
SELECT DISTINCT TRIM(agent_name), TRIM(supervisor), TRIM(manager), TRIM(tenure_bucket), TRIM(agent_shift)
FROM stg_soporte
ORDER BY 1;

-- order_id es único en el CSV (verificado), así que no hace falta deduplicar.
INSERT INTO pedidos (order_id, fecha_pedido, ciudad_cliente, categoria_producto, precio_item)
SELECT s.order_id::UUID,
       TO_TIMESTAMP(NULLIF(TRIM(s.order_date_time), ''), 'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       INITCAP(NULLIF(TRIM(s.customer_city), '')),
       NULLIF(TRIM(s.product_category), ''),
       NULLIF(NULLIF(TRIM(s.item_price), '')::NUMERIC, 0)
FROM stg_soporte s
WHERE s.order_id IS NOT NULL;

-- Normalización de una categoría con error de tipeo en origen (ver 'Home Appliences').
UPDATE pedidos
SET categoria_producto = 'Home Appliances'
WHERE categoria_producto = 'Home Appliences';

-- Los JOIN son 1 a 1 (categoría, subcategoría y agente son únicos), así que
-- tickets debe terminar con EXACTAMENTE las mismas filas que stg_soporte.
-- Lo comprobamos en el paso 7 para detectar explosión o pérdida de filas.
INSERT INTO tickets (ticket_id, canal, subcategoria_id, order_id, agente_id,
                     fecha_reporte, fecha_respuesta, fecha_encuesta,
                     tiempo_respuesta_min, tiempo_atencion, csat, comentario)
SELECT s.unique_id::UUID,
       TRIM(s.channel_name),
       sc.subcategoria_id,
       s.order_id::UUID,
       a.agente_id,
       TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       TO_TIMESTAMP(TRIM(s.issue_responded),   'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       TO_DATE(TRIM(s.survey_response_date), 'DD-Mon-YY'),
       CASE
           WHEN TO_TIMESTAMP(TRIM(s.issue_responded),   'DD/MM/YYYY HH24:MI')
             >= TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')
           THEN ROUND((EXTRACT(EPOCH FROM (
                    TO_TIMESTAMP(TRIM(s.issue_responded),   'DD/MM/YYYY HH24:MI')
                  - TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')
                )) / 60)::NUMERIC, 1)
       END,                                                        -- sin ELSE: los casos inválidos quedan NULL
       ROUND(NULLIF(TRIM(s.connected_handling_time), '')::NUMERIC)::INTEGER,
       TRIM(s.csat_score)::SMALLINT,
       NULLIF(TRIM(s.customer_remarks), '')
FROM stg_soporte s
JOIN categorias    c  ON c.nombre = TRIM(s.category)
JOIN subcategorias sc ON sc.categoria_id = c.categoria_id
                     AND sc.nombre = TRIM(s.sub_category)
JOIN agentes       a  ON a.nombre = TRIM(s.agent_name);


-- =============================================================================
-- 6. ÍNDICES
-- Solo sobre las columnas que usamos en JOIN y filtros del análisis. No indexamos
-- todo: cada índice extra enlentece las cargas y ocupa espacio.
-- (PostgreSQL indexa las PK automáticamente, pero NO las claves foráneas.)
-- =============================================================================
CREATE INDEX idx_tickets_order_id        ON tickets (order_id);
CREATE INDEX idx_tickets_agente_id       ON tickets (agente_id);
CREATE INDEX idx_tickets_subcategoria_id ON tickets (subcategoria_id);
CREATE INDEX idx_pedidos_fecha           ON pedidos (fecha_pedido);

ANALYZE;  -- actualiza estadísticas para que el planificador use bien los índices


-- =============================================================================
-- 7. VERIFICACIÓN DE LA CARGA
-- Valores esperados con el CSV original:
--   stg_soporte 85.907 | categorias 12 | subcategorias 59 | agentes 1.371
--   pedidos 67.675     | tickets 85.907
-- Si tickets != stg_soporte, revisar los JOIN del paso 5 (llaves duplicadas o faltantes).
-- Si todo da 0, falta cargar el CSV (paso 3) y volver a ejecutar este archivo.
-- =============================================================================
SELECT 'stg_soporte'   AS tabla, COUNT(*) AS filas FROM stg_soporte
UNION ALL SELECT 'categorias',    COUNT(*) FROM categorias
UNION ALL SELECT 'subcategorias', COUNT(*) FROM subcategorias
UNION ALL SELECT 'agentes',       COUNT(*) FROM agentes
UNION ALL SELECT 'pedidos',       COUNT(*) FROM pedidos
UNION ALL SELECT 'tickets',       COUNT(*) FROM tickets;
