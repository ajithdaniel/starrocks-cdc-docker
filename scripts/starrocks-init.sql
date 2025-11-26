-- =============================================================================
-- StarRocks Target Tables - Shared-Data Mode with Primary Key
-- These tables are optimized for CDC ingestion
-- =============================================================================

-- Create database
CREATE DATABASE IF NOT EXISTS cdc_db;
USE cdc_db;

-- =============================================================================
-- Table 1: Orders (Primary Key table for real-time updates)
-- =============================================================================
CREATE TABLE IF NOT EXISTS orders (
    order_id BIGINT NOT NULL,
    customer_id INT NOT NULL,
    order_status VARCHAR(50) NOT NULL,
    total_amount DECIMAL(12, 2) NOT NULL,
    shipping_address VARCHAR(500),
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
)
PRIMARY KEY (order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 4
PROPERTIES (
    "replication_num" = "1",
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- =============================================================================
-- Table 2: Customers (Primary Key table with partial update support)
-- =============================================================================
CREATE TABLE IF NOT EXISTS customers (
    customer_id INT NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(20),
    registration_date DATE NOT NULL,
    customer_tier VARCHAR(20),
    total_orders INT,
    total_spent DECIMAL(14, 2),
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
)
PRIMARY KEY (customer_id)
DISTRIBUTED BY HASH(customer_id) BUCKETS 4
PROPERTIES (
    "replication_num" = "1",
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- =============================================================================
-- Table 3: Products (Primary Key table)
-- =============================================================================
CREATE TABLE IF NOT EXISTS products (
    product_id INT NOT NULL,
    sku VARCHAR(50) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock_quantity INT NOT NULL,
    is_active BOOLEAN,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
)
PRIMARY KEY (product_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 4
PROPERTIES (
    "replication_num" = "1",
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- =============================================================================
-- Table 4: Order Items (Primary Key table)
-- =============================================================================
CREATE TABLE IF NOT EXISTS order_items (
    item_id BIGINT NOT NULL,
    order_id BIGINT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL,
    total_price DECIMAL(12, 2) NOT NULL,
    created_at DATETIME NOT NULL
)
PRIMARY KEY (item_id)
DISTRIBUTED BY HASH(item_id) BUCKETS 4
PROPERTIES (
    "replication_num" = "1",
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- =============================================================================
-- Table 5: Inventory Movements (Primary Key table - High frequency)
-- =============================================================================
CREATE TABLE IF NOT EXISTS inventory_movements (
    movement_id BIGINT NOT NULL,
    product_id INT NOT NULL,
    movement_type VARCHAR(20) NOT NULL,
    quantity INT NOT NULL,
    reference_id BIGINT,
    notes VARCHAR(500),
    created_at DATETIME NOT NULL
)
PRIMARY KEY (movement_id)
DISTRIBUTED BY HASH(movement_id) BUCKETS 4
PROPERTIES (
    "replication_num" = "1",
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- =============================================================================
-- Materialized Views for Analytics (Optional - created after CDC is running)
-- =============================================================================

-- Daily Order Summary
-- CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_order_summary
-- DISTRIBUTED BY HASH(order_date) BUCKETS 2
-- REFRESH ASYNC EVERY (INTERVAL 5 MINUTE)
-- AS
-- SELECT 
--     DATE(created_at) as order_date,
--     COUNT(*) as total_orders,
--     SUM(total_amount) as total_revenue,
--     AVG(total_amount) as avg_order_value,
--     COUNT(DISTINCT customer_id) as unique_customers
-- FROM orders
-- GROUP BY DATE(created_at);

-- Customer Tier Summary
-- CREATE MATERIALIZED VIEW IF NOT EXISTS mv_customer_tier_summary
-- DISTRIBUTED BY HASH(customer_tier) BUCKETS 2
-- REFRESH ASYNC EVERY (INTERVAL 5 MINUTE)
-- AS
-- SELECT 
--     customer_tier,
--     COUNT(*) as customer_count,
--     SUM(total_orders) as total_orders,
--     SUM(total_spent) as total_revenue,
--     AVG(total_spent) as avg_customer_value
-- FROM customers
-- GROUP BY customer_tier;

SELECT 'StarRocks tables created successfully!' AS status;
