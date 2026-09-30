# Capstone Project: Análisis de Calidad de Soporte (PostgreSQL)

Análisis exploratorio de datos sobre **85.907 tickets de soporte** de un e-commerce. El objetivo principal es identificar quiebres en la satisfacción del cliente (CSAT) y proponer mejoras operativas basadas en datos.

## 1. Contexto de Negocio

El área de soporte gestiona interacciones vía Inbound, Outcall y Email. Tras cada contacto, el cliente califica la atención de 1 a 5 (CSAT). El análisis busca responder:
1. ¿Qué motivos de contacto concentran el volumen y cuáles generan mayor fricción?
2. ¿Cuál es el impacto del tiempo de respuesta en el CSAT?
3. ¿Existe variación de rendimiento según el canal o la antigüedad del agente?
4. ¿Qué impacto económico (ventas) está asociado a los tickets reportados?

> **Métricas:** Satisfecho (CSAT 4-5) | Insatisfecho (CSAT 1-2). Las métricas financieras consideran únicamente el valor de los pedidos asociados a tickets abiertos.

## 2. Dataset y Modelo de Datos

- **Origen:** `Customer_support_data.csv` (85.907 filas × 20 columnas). Rango temporal: 28/07/2023 - 31/08/2023.
- **Estructura:** Se implementó un modelo relacional normalizado para optimizar consultas y reducir redundancia, pasando de una tabla desnormalizada a un esquema en copo de nieve/estrella.

*Nota de diseño:* Dado que el dataset original carece de un maestro de clientes y catálogo, el análisis de clientes se aproximó utilizando la dimensión geográfica (`ciudad`), y el análisis de productos mediante la `categoría de producto`.

```mermaid
erDiagram
    categorias    ||--o{ subcategorias : "agrupa"
    subcategorias ||--o{ tickets       : "clasifica"
    agentes       ||--o{ tickets       : "atiende"
    pedidos       |o--o{ tickets       : "origina"

    categorias {
        smallint categoria_id PK
        varchar nombre
    }
    subcategorias {
        smallint subcategoria_id PK
        smallint categoria_id FK
        varchar nombre
    }
    agentes {
        int agente_id PK
        varchar nombre
        varchar supervisor
        varchar manager
        varchar antiguedad
        varchar turno
    }
    pedidos {
        uuid order_id PK
        timestamp fecha_pedido
        varchar ciudad_cliente
        varchar categoria_producto
        numeric precio_item
    }
    tickets {
        uuid ticket_id PK
        varchar canal
        smallint subcategoria_id FK
        uuid order_id FK
        int agente_id FK
        timestamp fecha_reporte
        timestamp fecha_respuesta
        date fecha_encuesta
        numeric tiempo_respuesta_min
        smallint csat
        text comentario
    }
