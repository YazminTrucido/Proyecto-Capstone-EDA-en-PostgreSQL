-- =============================================================================
-- estructura.sql  ·  Capstone Project
-- =============================================================================

DROP TABLE IF EXISTS tickets, pedidos, agentes, subcategorias, categorias CASCADE;

-- =============================================================================
-- 1. STAGING
-- Tipos de dato TEXT para ingesta raw segura y posterior casteo/limpieza.
-- =============================================================================
CREATE TABLE IF NOT EXISTS stg_soporte (
    unique_id TEXT,
    channel_name TEXT,
    category TEXT,
    sub_category TEXT,
    customer_remarks TEXT,
    order_id TEXT,
    order_date_time TEXT,
    issue_reported_at TEXT,
    issue_responded TEXT,
    survey_response_date TEXT,
    customer_city TEXT,
    product_category TEXT,
    item_price TEXT,
    connected_handling_time TEXT,
    agent_name TEXT,
    supervisor TEXT,
    manager TEXT,
    tenure_bucket TEXT,
    agent_shift TEXT,
    csat_score TEXT
);

-- =============================================================================
-- 2. MODELO FÍSICO NORMALIZADO (3NF)
-- =============================================================================
CREATE TABLE categorias (
    categoria_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre VARCHAR(40) NOT NULL UNIQUE
);

CREATE TABLE subcategorias (
    subcategoria_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    categoria_id SMALLINT NOT NULL REFERENCES categorias (categoria_id),
    nombre VARCHAR(60) NOT NULL,
    UNIQUE (categoria_id, nombre)
);

CREATE TABLE agentes (
    agente_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre VARCHAR(60) NOT NULL UNIQUE,
    supervisor VARCHAR(60) NOT NULL,
    manager VARCHAR(60) NOT NULL,
    antiguedad VARCHAR(20) NOT NULL,
    turno VARCHAR(20) NOT NULL
);

CREATE TABLE pedidos (
    order_id UUID PRIMARY KEY,
    fecha_pedido TIMESTAMP,
    ciudad_cliente VARCHAR(60),
    categoria_producto VARCHAR(40),
    precio_item NUMERIC(12, 2) CHECK (precio_item > 0)
);

CREATE TABLE tickets (
    ticket_id UUID PRIMARY KEY,
    canal VARCHAR(20) NOT NULL,
    subcategoria_id SMALLINT NOT NULL REFERENCES subcategorias (subcategoria_id),
    order_id UUID REFERENCES pedidos (order_id),
    agente_id INTEGER NOT NULL REFERENCES agentes (agente_id),
    fecha_reporte TIMESTAMP NOT NULL,
    fecha_respuesta TIMESTAMP NOT NULL,
    fecha_encuesta DATE NOT NULL,
    tiempo_respuesta_min NUMERIC(8, 1),
    tiempo_atencion INTEGER,
    csat SMALLINT NOT NULL CHECK (csat BETWEEN 1 AND 5),
    comentario TEXT
);

-- =============================================================================
-- 3. ETL Y POBLADO DE TABLAS
-- =============================================================================
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

-- Asunción: El nombre de agente funciona como primary business key.
INSERT INTO agentes (nombre, supervisor, manager, antiguedad, turno)
SELECT DISTINCT TRIM(agent_name), TRIM(supervisor), TRIM(manager), TRIM(tenure_bucket), TRIM(agent_shift)
FROM stg_soporte
ORDER BY 1;

INSERT INTO pedidos (order_id, fecha_pedido, ciudad_cliente, categoria_producto, precio_item)
SELECT s.order_id::UUID,
       TO_TIMESTAMP(NULLIF(TRIM(s.order_date_time), ''), 'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       INITCAP(NULLIF(TRIM(s.customer_city), '')),
       NULLIF(TRIM(s.product_category), ''),
       NULLIF(NULLIF(TRIM(s.item_price), '')::NUMERIC, 0)
FROM stg_soporte s
WHERE s.order_id IS NOT NULL;

-- Limpieza QA
UPDATE pedidos
SET categoria_producto = 'Home Appliances'
WHERE categoria_producto = 'Home Appliences';

-- Join principal y cálculo de SLA en la ingesta
INSERT INTO tickets (ticket_id, canal, subcategoria_id, order_id, agente_id,
                     fecha_reporte, fecha_respuesta, fecha_encuesta,
                     tiempo_respuesta_min, tiempo_atencion, csat, comentario)
SELECT s.unique_id::UUID,
       TRIM(s.channel_name),
       sc.subcategoria_id,
       s.order_id::UUID,
       a.agente_id,
       TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       TO_TIMESTAMP(TRIM(s.issue_responded), 'DD/MM/YYYY HH24:MI')::TIMESTAMP,
       TO_DATE(TRIM(s.survey_response_date), 'DD-Mon-YY'),
       CASE
           WHEN TO_TIMESTAMP(TRIM(s.issue_responded), 'DD/MM/YYYY HH24:MI')
             >= TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')
           THEN ROUND((EXTRACT(EPOCH FROM (
                    TO_TIMESTAMP(TRIM(s.issue_responded), 'DD/MM/YYYY HH24:MI')
                  - TO_TIMESTAMP(TRIM(s.issue_reported_at), 'DD/MM/YYYY HH24:MI')
                )) / 60)::NUMERIC, 1)
       END,
       ROUND(NULLIF(TRIM(s.connected_handling_time), '')::NUMERIC)::INTEGER,
       TRIM(s.csat_score)::SMALLINT,
       NULLIF(TRIM(s.customer_remarks), '')
FROM stg_soporte s
JOIN categorias c  ON c.nombre = TRIM(s.category)
JOIN subcategorias sc ON sc.categoria_id = c.categoria_id
                     AND sc.nombre = TRIM(s.sub_category)
JOIN agentes a  ON a.nombre = TRIM(s.agent_name);

-- =============================================================================
-- 4. ÍNDICES DE PERFORMANCE
-- =============================================================================
CREATE INDEX idx_tickets_order_id ON tickets (order_id);
CREATE INDEX idx_tickets_agente_id ON tickets (agente_id);
CREATE INDEX idx_tickets_subcategoria_id ON tickets (subcategoria_id);
CREATE INDEX idx_pedidos_fecha ON pedidos (fecha_pedido);

ANALYZE;

-- =============================================================================
-- QA Checks
-- =============================================================================
/*
SELECT 'stg_soporte' AS tabla, COUNT(*) AS filas FROM stg_soporte
UNION ALL SELECT 'categorias', COUNT(*) FROM categorias
UNION ALL SELECT 'subcategorias', COUNT(*) FROM subcategorias
UNION ALL SELECT 'agentes', COUNT(*) FROM agentes
UNION ALL SELECT 'pedidos', COUNT(*) FROM pedidos
UNION ALL SELECT 'tickets', COUNT(*) FROM tickets;
*/
