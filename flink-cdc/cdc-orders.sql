-- Flink SQL CDC Job for Orders table
-- This script syncs the orders table from MySQL to StarRocks

SET 'execution.checkpointing.interval' = '10s';
SET 'parallelism.default' = '2';

-- MySQL CDC Source for orders
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

-- StarRocks Sink for orders
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

-- Insert from MySQL to StarRocks (CDC sync)
INSERT INTO starrocks_orders SELECT * FROM mysql_orders;
