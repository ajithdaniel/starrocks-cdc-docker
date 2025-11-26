-- =============================================================================
-- MySQL Source Database Initialization
-- Sample tables for CDC demonstration
-- =============================================================================

-- Create CDC user with replication privileges
CREATE USER IF NOT EXISTS 'cdc_user'@'%' IDENTIFIED BY 'cdc_pass123';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'cdc_user'@'%';
GRANT ALL PRIVILEGES ON source_db.* TO 'cdc_user'@'%';
FLUSH PRIVILEGES;

-- Switch to source database
USE source_db;

-- =============================================================================
-- Table 1: Orders (Main transactional table)
-- =============================================================================
CREATE TABLE IF NOT EXISTS orders (
    order_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    customer_id INT NOT NULL,
    order_status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    total_amount DECIMAL(12, 2) NOT NULL DEFAULT 0.00,
    shipping_address VARCHAR(500),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_customer_id (customer_id),
    INDEX idx_order_status (order_status),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =============================================================================
-- Table 2: Customers (Master data)
-- =============================================================================
CREATE TABLE IF NOT EXISTS customers (
    customer_id INT PRIMARY KEY AUTO_INCREMENT,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    phone VARCHAR(20),
    registration_date DATE NOT NULL,
    customer_tier VARCHAR(20) DEFAULT 'STANDARD',
    total_orders INT DEFAULT 0,
    total_spent DECIMAL(14, 2) DEFAULT 0.00,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_email (email),
    INDEX idx_customer_tier (customer_tier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =============================================================================
-- Table 3: Products (Catalog data)
-- =============================================================================
CREATE TABLE IF NOT EXISTS products (
    product_id INT PRIMARY KEY AUTO_INCREMENT,
    sku VARCHAR(50) NOT NULL UNIQUE,
    product_name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock_quantity INT NOT NULL DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_sku (sku),
    INDEX idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =============================================================================
-- Table 4: Order Items (Order details)
-- =============================================================================
CREATE TABLE IF NOT EXISTS order_items (
    item_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    order_id BIGINT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL DEFAULT 1,
    unit_price DECIMAL(10, 2) NOT NULL,
    total_price DECIMAL(12, 2) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_order_id (order_id),
    INDEX idx_product_id (product_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =============================================================================
-- Table 5: Inventory Movements (High-frequency updates)
-- =============================================================================
CREATE TABLE IF NOT EXISTS inventory_movements (
    movement_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    product_id INT NOT NULL,
    movement_type VARCHAR(20) NOT NULL,  -- 'IN', 'OUT', 'ADJUSTMENT'
    quantity INT NOT NULL,
    reference_id BIGINT,  -- order_id or purchase_order_id
    notes VARCHAR(500),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_product_id (product_id),
    INDEX idx_movement_type (movement_type),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =============================================================================
-- Insert Sample Data
-- =============================================================================

-- Insert Customers
INSERT INTO customers (first_name, last_name, email, phone, registration_date, customer_tier) VALUES
('John', 'Smith', 'john.smith@email.com', '+1-555-0101', '2023-01-15', 'GOLD'),
('Jane', 'Doe', 'jane.doe@email.com', '+1-555-0102', '2023-02-20', 'STANDARD'),
('Robert', 'Johnson', 'robert.j@email.com', '+1-555-0103', '2023-03-10', 'PLATINUM'),
('Emily', 'Williams', 'emily.w@email.com', '+1-555-0104', '2023-04-05', 'GOLD'),
('Michael', 'Brown', 'michael.b@email.com', '+1-555-0105', '2023-05-12', 'STANDARD'),
('Sarah', 'Davis', 'sarah.d@email.com', '+1-555-0106', '2023-06-18', 'STANDARD'),
('David', 'Miller', 'david.m@email.com', '+1-555-0107', '2023-07-22', 'GOLD'),
('Lisa', 'Wilson', 'lisa.w@email.com', '+1-555-0108', '2023-08-30', 'PLATINUM'),
('James', 'Moore', 'james.m@email.com', '+1-555-0109', '2023-09-14', 'STANDARD'),
('Jennifer', 'Taylor', 'jennifer.t@email.com', '+1-555-0110', '2023-10-25', 'GOLD');

-- Insert Products
INSERT INTO products (sku, product_name, category, price, stock_quantity) VALUES
('LAPTOP-001', 'ProBook Laptop 15"', 'Electronics', 999.99, 50),
('PHONE-001', 'SmartPhone X12', 'Electronics', 799.99, 100),
('TABLET-001', 'TabletPro 10"', 'Electronics', 499.99, 75),
('HEADPHONE-001', 'Wireless Headphones Pro', 'Electronics', 199.99, 200),
('WATCH-001', 'Smart Watch Elite', 'Electronics', 299.99, 150),
('CAMERA-001', 'Digital Camera 4K', 'Electronics', 649.99, 30),
('SPEAKER-001', 'Bluetooth Speaker', 'Electronics', 79.99, 300),
('KEYBOARD-001', 'Mechanical Keyboard RGB', 'Accessories', 129.99, 120),
('MOUSE-001', 'Wireless Gaming Mouse', 'Accessories', 69.99, 250),
('MONITOR-001', '27" 4K Monitor', 'Electronics', 449.99, 40);

-- Insert Orders
INSERT INTO orders (customer_id, order_status, total_amount, shipping_address) VALUES
(1, 'DELIVERED', 1199.98, '123 Main St, New York, NY 10001'),
(2, 'SHIPPED', 799.99, '456 Oak Ave, Los Angeles, CA 90001'),
(3, 'PROCESSING', 1549.97, '789 Pine Rd, Chicago, IL 60601'),
(1, 'PENDING', 299.99, '123 Main St, New York, NY 10001'),
(4, 'DELIVERED', 579.98, '321 Elm St, Houston, TX 77001'),
(5, 'CANCELLED', 199.99, '654 Maple Dr, Phoenix, AZ 85001'),
(6, 'SHIPPED', 929.98, '987 Cedar Ln, Philadelphia, PA 19101'),
(7, 'DELIVERED', 1449.97, '147 Birch Way, San Antonio, TX 78201'),
(8, 'PROCESSING', 449.99, '258 Spruce Ct, San Diego, CA 92101'),
(9, 'PENDING', 149.98, '369 Willow Blvd, Dallas, TX 75201');

-- Insert Order Items
INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price) VALUES
(1, 1, 1, 999.99, 999.99),
(1, 4, 1, 199.99, 199.99),
(2, 2, 1, 799.99, 799.99),
(3, 1, 1, 999.99, 999.99),
(3, 3, 1, 499.99, 499.99),
(3, 9, 1, 69.99, 69.99),
(4, 5, 1, 299.99, 299.99),
(5, 4, 1, 199.99, 199.99),
(5, 7, 1, 79.99, 79.99),
(5, 9, 2, 69.99, 139.98),
(5, 8, 1, 129.99, 129.99),
(6, 4, 1, 199.99, 199.99),
(7, 2, 1, 799.99, 799.99),
(7, 8, 1, 129.99, 129.99),
(8, 1, 1, 999.99, 999.99),
(8, 10, 1, 449.99, 449.99),
(9, 10, 1, 449.99, 449.99),
(10, 7, 1, 79.99, 79.99),
(10, 9, 1, 69.99, 69.99);

-- Insert Inventory Movements
INSERT INTO inventory_movements (product_id, movement_type, quantity, reference_id, notes) VALUES
(1, 'IN', 100, NULL, 'Initial stock'),
(2, 'IN', 200, NULL, 'Initial stock'),
(3, 'IN', 150, NULL, 'Initial stock'),
(1, 'OUT', 2, 1, 'Order fulfillment'),
(2, 'OUT', 2, 2, 'Order fulfillment'),
(4, 'OUT', 3, 1, 'Order fulfillment'),
(1, 'ADJUSTMENT', -5, NULL, 'Inventory count correction'),
(5, 'IN', 50, NULL, 'Restock'),
(3, 'OUT', 1, 3, 'Order fulfillment'),
(7, 'OUT', 2, 5, 'Order fulfillment');

-- Update customer statistics
UPDATE customers SET total_orders = 2, total_spent = 1499.97 WHERE customer_id = 1;
UPDATE customers SET total_orders = 1, total_spent = 799.99 WHERE customer_id = 2;
UPDATE customers SET total_orders = 1, total_spent = 1549.97 WHERE customer_id = 3;
UPDATE customers SET total_orders = 1, total_spent = 579.98 WHERE customer_id = 4;
UPDATE customers SET total_orders = 1, total_spent = 0.00 WHERE customer_id = 5;
UPDATE customers SET total_orders = 1, total_spent = 929.98 WHERE customer_id = 6;
UPDATE customers SET total_orders = 1, total_spent = 1449.97 WHERE customer_id = 7;
UPDATE customers SET total_orders = 1, total_spent = 449.99 WHERE customer_id = 8;
UPDATE customers SET total_orders = 1, total_spent = 149.98 WHERE customer_id = 9;

SELECT 'MySQL initialization completed successfully!' AS status;
