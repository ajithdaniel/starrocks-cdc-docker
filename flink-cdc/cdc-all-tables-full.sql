-- Flink SQL CDC Job for ALL tables with FULL schema
-- This script syncs all tables from MySQL to StarRocks

SET 'execution.checkpointing.interval' = '10s';
SET 'parallelism.default' = '2';

-- =============================================================================
-- ORDERS TABLE
-- =============================================================================

CREATE TABLE mysql_orders (
    order_id BIGINT,
    customer_id INT,
    order_status STRING,
    total_amount DECIMAL(12, 2),
    shipping_address STRING,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql',
    'port' = '3306',
    'username' = 'cdc_user',
    'password' = 'cdc_pass123',
    'database-name' = 'source_db',
    'table-name' = 'orders',
    'server-id' = '5401',
    'scan.startup.mode' = 'initial'
);

CREATE TABLE starrocks_orders (
    order_id BIGINT,
    customer_id INT,
    order_status STRING,
    total_amount DECIMAL(12, 2),
    shipping_address STRING,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'cdc_db',
    'table-name' = 'orders',
    'username' = 'root',
    'password' = '',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'at-least-once'
);

INSERT INTO starrocks_orders SELECT * FROM mysql_orders;

-- =============================================================================
-- CUSTOMERS TABLE (full schema)
-- =============================================================================

CREATE TABLE mysql_customers (
    customer_id INT,
    first_name STRING,
    last_name STRING,
    email STRING,
    phone STRING,
    registration_date DATE,
    customer_tier STRING,
    total_orders INT,
    total_spent DECIMAL(14, 2),
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql',
    'port' = '3306',
    'username' = 'cdc_user',
    'password' = 'cdc_pass123',
    'database-name' = 'source_db',
    'table-name' = 'customers',
    'server-id' = '5402',
    'scan.startup.mode' = 'initial'
);

CREATE TABLE starrocks_customers (
    customer_id INT,
    first_name STRING,
    last_name STRING,
    email STRING,
    phone STRING,
    registration_date DATE,
    customer_tier STRING,
    total_orders INT,
    total_spent DECIMAL(14, 2),
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'cdc_db',
    'table-name' = 'customers',
    'username' = 'root',
    'password' = '',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'at-least-once'
);

INSERT INTO starrocks_customers SELECT * FROM mysql_customers;

-- =============================================================================
-- PRODUCTS TABLE (full schema)
-- =============================================================================

CREATE TABLE mysql_products (
    product_id INT,
    sku STRING,
    product_name STRING,
    category STRING,
    price DECIMAL(10, 2),
    stock_quantity INT,
    is_active BOOLEAN,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql',
    'port' = '3306',
    'username' = 'cdc_user',
    'password' = 'cdc_pass123',
    'database-name' = 'source_db',
    'table-name' = 'products',
    'server-id' = '5403',
    'scan.startup.mode' = 'initial'
);

CREATE TABLE starrocks_products (
    product_id INT,
    sku STRING,
    product_name STRING,
    category STRING,
    price DECIMAL(10, 2),
    stock_quantity INT,
    is_active BOOLEAN,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'cdc_db',
    'table-name' = 'products',
    'username' = 'root',
    'password' = '',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'at-least-once'
);

INSERT INTO starrocks_products SELECT * FROM mysql_products;

-- =============================================================================
-- ORDER_ITEMS TABLE (full schema)
-- =============================================================================

CREATE TABLE mysql_order_items (
    item_id BIGINT,
    order_id BIGINT,
    product_id INT,
    quantity INT,
    unit_price DECIMAL(10, 2),
    total_price DECIMAL(12, 2),
    created_at TIMESTAMP(3),
    PRIMARY KEY (item_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql',
    'port' = '3306',
    'username' = 'cdc_user',
    'password' = 'cdc_pass123',
    'database-name' = 'source_db',
    'table-name' = 'order_items',
    'server-id' = '5404',
    'scan.startup.mode' = 'initial'
);

CREATE TABLE starrocks_order_items (
    item_id BIGINT,
    order_id BIGINT,
    product_id INT,
    quantity INT,
    unit_price DECIMAL(10, 2),
    total_price DECIMAL(12, 2),
    created_at TIMESTAMP(3),
    PRIMARY KEY (item_id) NOT ENFORCED
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'cdc_db',
    'table-name' = 'order_items',
    'username' = 'root',
    'password' = '',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'at-least-once'
);

INSERT INTO starrocks_order_items SELECT * FROM mysql_order_items;

-- =============================================================================
-- INVENTORY_MOVEMENTS TABLE (full schema)
-- =============================================================================

CREATE TABLE mysql_inventory_movements (
    movement_id BIGINT,
    product_id INT,
    movement_type STRING,
    quantity INT,
    reference_id BIGINT,
    notes STRING,
    created_at TIMESTAMP(3),
    PRIMARY KEY (movement_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql',
    'port' = '3306',
    'username' = 'cdc_user',
    'password' = 'cdc_pass123',
    'database-name' = 'source_db',
    'table-name' = 'inventory_movements',
    'server-id' = '5405',
    'scan.startup.mode' = 'initial'
);

CREATE TABLE starrocks_inventory_movements (
    movement_id BIGINT,
    product_id INT,
    movement_type STRING,
    quantity INT,
    reference_id BIGINT,
    notes STRING,
    created_at TIMESTAMP(3),
    PRIMARY KEY (movement_id) NOT ENFORCED
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'cdc_db',
    'table-name' = 'inventory_movements',
    'username' = 'root',
    'password' = '',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'at-least-once'
);

INSERT INTO starrocks_inventory_movements SELECT * FROM mysql_inventory_movements;
