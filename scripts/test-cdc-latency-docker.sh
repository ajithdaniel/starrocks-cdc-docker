#!/bin/bash
# =============================================================================
# CDC Latency Test Script (Docker Version)
# Tests MySQL to StarRocks CDC pipeline performance and latency
# Supports ALL tables: orders, customers, products, order_items, inventory_movements
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test parameters
BATCH_SIZE="${BATCH_SIZE:-100}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-60}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"

# All tables in the CDC pipeline
ALL_TABLES=("orders" "customers" "products" "order_items" "inventory_movements")

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=============================================${NC}"
}

mysql_cmd() {
    docker exec mysql-source mysql -u cdc_user -pcdc_pass123 source_db -N -e "$1" 2>/dev/null
}

starrocks_cmd() {
    docker exec starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root cdc_db -N -e "$1" 2>/dev/null
}

get_timestamp_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

# =============================================================================
# Multi-Table Insert Functions
# =============================================================================

insert_customer() {
    local marker=$1
    mysql_cmd "INSERT INTO customers (first_name, last_name, email, phone, registration_date, customer_tier, total_orders, total_spent)
               VALUES ('Test', 'User_$marker', 'test_${marker}@example.com', '555-0000', CURDATE(), 'BRONZE', 0, 0.00);"
}

insert_product() {
    local marker=$1
    local price=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))
    mysql_cmd "INSERT INTO products (sku, product_name, category, price, stock_quantity, is_active)
               VALUES ('SKU_$marker', 'Test Product $marker', 'TEST', $price, 100, true);"
}

insert_order_item() {
    local marker=$1
    local order_id=$2
    local product_id=$3
    local qty=$((($RANDOM % 5) + 1))
    local unit_price=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))
    local total_price=$(printf "%.2f" $(echo "$qty * $unit_price" | bc -l))
    mysql_cmd "INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
               VALUES ($order_id, $product_id, $qty, $unit_price, $total_price);"
}

insert_inventory_movement() {
    local marker=$1
    local product_id=$2
    local qty=$((($RANDOM % 50) + 1))
    mysql_cmd "INSERT INTO inventory_movements (product_id, movement_type, quantity, reference_id, notes)
               VALUES ($product_id, 'IN', $qty, NULL, 'Test movement $marker');"
}

# =============================================================================
# Test Functions
# =============================================================================

test_single_insert() {
    log_header "Test 1: Single Insert Latency"

    local test_id="latency_test_$(date +%s)"
    local start_time=$(get_timestamp_ms)

    log_info "Inserting single order with marker: $test_id"

    # Insert into MySQL
    mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
               VALUES (1, 'TEST', 123.45, '$test_id');"

    local insert_time=$(get_timestamp_ms)
    log_info "Insert completed in $((insert_time - start_time))ms"

    # Wait for sync
    log_info "Waiting for CDC sync..."
    local attempt=0
    local synced=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE shipping_address='$test_id';" 2>/dev/null || echo "0")

        if [ "$count" -ge "1" ]; then
            synced=1
            break
        fi

        sleep $CHECK_INTERVAL
        ((attempt++))
    done

    local end_time=$(get_timestamp_ms)
    local latency=$((end_time - insert_time))

    if [ $synced -eq 1 ]; then
        log_info "Single insert latency: ${latency}ms"
        echo "$latency"
    else
        log_error "Sync timeout after ${MAX_WAIT_SECONDS}s"
        echo "-1"
    fi
}

test_all_tables_insert() {
    log_header "Test: Multi-Table Insert Latency"

    local test_marker="multi_$(date +%s)"
    local start_time=$(get_timestamp_ms)

    log_info "Inserting test data into ALL tables with marker: $test_marker"

    # Insert customer
    log_info "  Inserting customer..."
    insert_customer "$test_marker"
    local customer_id=$(mysql_cmd "SELECT customer_id FROM customers WHERE email='test_${test_marker}@example.com' LIMIT 1;")

    # Insert product
    log_info "  Inserting product..."
    insert_product "$test_marker"
    local product_id=$(mysql_cmd "SELECT product_id FROM products WHERE sku='SKU_$test_marker' LIMIT 1;")

    # Insert order
    log_info "  Inserting order..."
    mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
               VALUES ($customer_id, 'MULTI_TEST', 99.99, 'multi_addr_$test_marker');"
    local order_id=$(mysql_cmd "SELECT order_id FROM orders WHERE shipping_address='multi_addr_$test_marker' LIMIT 1;")

    # Insert order item
    log_info "  Inserting order_item..."
    insert_order_item "$test_marker" "$order_id" "$product_id"

    # Insert inventory movement
    log_info "  Inserting inventory_movement..."
    insert_inventory_movement "$test_marker" "$product_id"

    local insert_time=$(get_timestamp_ms)
    log_info "All inserts completed in $((insert_time - start_time))ms"

    # Wait for all tables to sync
    log_info "Waiting for CDC sync across all tables..."
    local attempt=0
    local all_synced=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local cust_count=$(starrocks_cmd "SELECT COUNT(*) FROM customers WHERE email='test_${test_marker}@example.com';" 2>/dev/null || echo "0")
        local prod_count=$(starrocks_cmd "SELECT COUNT(*) FROM products WHERE sku='SKU_$test_marker';" 2>/dev/null || echo "0")
        local order_count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE shipping_address='multi_addr_$test_marker';" 2>/dev/null || echo "0")
        local item_count=$(starrocks_cmd "SELECT COUNT(*) FROM order_items WHERE order_id=$order_id;" 2>/dev/null || echo "0")
        local inv_count=$(starrocks_cmd "SELECT COUNT(*) FROM inventory_movements WHERE notes='Test movement $test_marker';" 2>/dev/null || echo "0")

        log_info "  Sync status: customers=$cust_count, products=$prod_count, orders=$order_count, order_items=$item_count, inventory=$inv_count"

        if [ "$cust_count" -ge "1" ] && [ "$prod_count" -ge "1" ] && [ "$order_count" -ge "1" ] && [ "$item_count" -ge "1" ] && [ "$inv_count" -ge "1" ]; then
            all_synced=1
            break
        fi

        sleep $CHECK_INTERVAL
        ((attempt++))
    done

    local end_time=$(get_timestamp_ms)
    local latency=$((end_time - insert_time))

    if [ $all_synced -eq 1 ]; then
        log_info "All tables synced! Total latency: ${latency}ms"
        echo "$latency"
    else
        log_error "Sync timeout - not all tables synced after ${MAX_WAIT_SECONDS}s"
        echo "-1"
    fi
}

test_batch_insert() {
    local batch_size=${1:-$BATCH_SIZE}

    log_header "Test 2: Batch Insert ($batch_size records)"

    local test_marker="batch_$(date +%s)"
    local start_time=$(get_timestamp_ms)

    log_info "Inserting $batch_size orders with marker: $test_marker"

    # Generate batch insert SQL
    local sql="INSERT INTO orders (customer_id, order_status, total_amount, shipping_address) VALUES "
    local values=""

    for i in $(seq 1 $batch_size); do
        if [ -n "$values" ]; then
            values="$values,"
        fi
        local customer_id=$((($i % 10) + 1))
        local amount=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))
        values="$values($customer_id, 'BATCH', $amount, '${test_marker}_$i')"
    done

    sql="$sql$values;"

    # Insert into MySQL
    mysql_cmd "$sql"

    local insert_time=$(get_timestamp_ms)
    local insert_duration=$((insert_time - start_time))
    local insert_rate=$(echo "scale=2; $batch_size * 1000 / $insert_duration" | bc)
    log_info "Batch insert completed in ${insert_duration}ms ($insert_rate records/sec)"

    # Wait for all records to sync
    log_info "Waiting for CDC sync of all $batch_size records..."
    local attempt=0
    local synced=0
    local last_count=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE shipping_address LIKE '${test_marker}_%';" 2>/dev/null || echo "0")

        if [ "$count" != "$last_count" ]; then
            log_info "  Synced: $count / $batch_size"
            last_count=$count
        fi

        if [ "$count" -ge "$batch_size" ]; then
            synced=1
            break
        fi

        sleep $CHECK_INTERVAL
        ((attempt++))
    done

    local end_time=$(get_timestamp_ms)
    local total_latency=$((end_time - insert_time))
    local throughput=$(echo "scale=2; $batch_size * 1000 / $total_latency" | bc)

    if [ $synced -eq 1 ]; then
        log_info "Batch sync completed!"
        log_info "  Total records: $batch_size"
        log_info "  Sync latency: ${total_latency}ms"
        log_info "  Throughput: $throughput records/sec"
        echo "$total_latency"
    else
        local final_count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE shipping_address LIKE '${test_marker}_%';" 2>/dev/null || echo "0")
        log_error "Sync incomplete after ${MAX_WAIT_SECONDS}s - only $final_count / $batch_size synced"
        echo "-1"
    fi
}

test_update_latency() {
    log_header "Test 3: Update Latency"

    # Get an existing order
    local order_id=$(mysql_cmd "SELECT order_id FROM orders ORDER BY order_id DESC LIMIT 1;")

    if [ -z "$order_id" ]; then
        log_error "No orders found to update"
        return
    fi

    local new_status="UPDATED_$(date +%s)"
    local start_time=$(get_timestamp_ms)

    log_info "Updating order $order_id with status: $new_status"

    # Update in MySQL
    mysql_cmd "UPDATE orders SET order_status='$new_status', updated_at=NOW() WHERE order_id=$order_id;"

    local update_time=$(get_timestamp_ms)
    log_info "Update completed in $((update_time - start_time))ms"

    # Wait for sync
    log_info "Waiting for CDC sync..."
    local attempt=0
    local synced=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local status=$(starrocks_cmd "SELECT order_status FROM orders WHERE order_id=$order_id;" 2>/dev/null || echo "")

        if [ "$status" == "$new_status" ]; then
            synced=1
            break
        fi

        sleep $CHECK_INTERVAL
        ((attempt++))
    done

    local end_time=$(get_timestamp_ms)
    local latency=$((end_time - update_time))

    if [ $synced -eq 1 ]; then
        log_info "Update sync latency: ${latency}ms"
        echo "$latency"
    else
        log_error "Sync timeout after ${MAX_WAIT_SECONDS}s"
        echo "-1"
    fi
}

test_delete_latency() {
    log_header "Test 4: Delete Latency"

    # Insert a record to delete
    local test_marker="delete_test_$(date +%s)"
    mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
               VALUES (1, 'TO_DELETE', 1.00, '$test_marker');"

    # Wait for it to sync first
    log_info "Waiting for insert to sync before delete test..."
    sleep 8

    local order_id=$(mysql_cmd "SELECT order_id FROM orders WHERE shipping_address='$test_marker' LIMIT 1;")

    if [ -z "$order_id" ]; then
        log_error "Could not find inserted order"
        return
    fi

    # Verify it exists in StarRocks
    local sr_count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE order_id=$order_id;" 2>/dev/null || echo "0")

    if [ "$sr_count" -lt "1" ]; then
        log_warn "Order not yet synced to StarRocks, waiting more..."
        sleep 10
    fi

    local start_time=$(get_timestamp_ms)

    log_info "Deleting order $order_id"

    # Delete from MySQL
    mysql_cmd "DELETE FROM orders WHERE order_id=$order_id;"

    local delete_time=$(get_timestamp_ms)
    log_info "Delete completed in $((delete_time - start_time))ms"

    # Wait for sync
    log_info "Waiting for CDC sync..."
    local attempt=0
    local synced=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local count=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE order_id=$order_id;" 2>/dev/null || echo "1")

        if [ "$count" -eq "0" ]; then
            synced=1
            break
        fi

        sleep $CHECK_INTERVAL
        ((attempt++))
    done

    local end_time=$(get_timestamp_ms)
    local latency=$((end_time - delete_time))

    if [ $synced -eq 1 ]; then
        log_info "Delete sync latency: ${latency}ms"
        echo "$latency"
    else
        log_error "Sync timeout after ${MAX_WAIT_SECONDS}s"
        echo "-1"
    fi
}

show_current_counts() {
    log_header "Current Data Counts"

    echo ""
    echo "MySQL Source:"
    echo "  orders:            $(mysql_cmd 'SELECT COUNT(*) FROM orders;')"
    echo "  customers:         $(mysql_cmd 'SELECT COUNT(*) FROM customers;')"
    echo "  products:          $(mysql_cmd 'SELECT COUNT(*) FROM products;')"
    echo "  order_items:       $(mysql_cmd 'SELECT COUNT(*) FROM order_items;')"
    echo "  inventory:         $(mysql_cmd 'SELECT COUNT(*) FROM inventory_movements;')"

    echo ""
    echo "StarRocks Target:"
    echo "  orders:            $(starrocks_cmd 'SELECT COUNT(*) FROM orders;' 2>/dev/null || echo 'N/A')"
    echo "  customers:         $(starrocks_cmd 'SELECT COUNT(*) FROM customers;' 2>/dev/null || echo 'N/A')"
    echo "  products:          $(starrocks_cmd 'SELECT COUNT(*) FROM products;' 2>/dev/null || echo 'N/A')"
    echo "  order_items:       $(starrocks_cmd 'SELECT COUNT(*) FROM order_items;' 2>/dev/null || echo 'N/A')"
    echo "  inventory:         $(starrocks_cmd 'SELECT COUNT(*) FROM inventory_movements;' 2>/dev/null || echo 'N/A')"
}

continuous_load() {
    local duration=${1:-30}
    local rate=${2:-5}  # records per second

    log_header "Continuous Load Test"
    log_info "Duration: ${duration}s, Target rate: ${rate} records/sec"

    local test_marker="continuous_$(date +%s)"
    local start_time=$(get_timestamp_ms)
    local total_inserted=0
    local sleep_interval=$(echo "scale=4; 1 / $rate" | bc)
    local iterations=$((duration * rate))

    log_info "Starting continuous insert (target: $iterations records)..."

    for i in $(seq 1 $iterations); do
        local customer_id=$((($RANDOM % 10) + 1))
        local amount=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))

        mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
                   VALUES ($customer_id, 'CONTINUOUS', $amount, '${test_marker}_$i');" 2>/dev/null

        ((total_inserted++))

        if [ $((total_inserted % 50)) -eq 0 ]; then
            local current_time=$(get_timestamp_ms)
            local elapsed=$((current_time - start_time))
            local actual_rate=$(echo "scale=2; $total_inserted * 1000 / $elapsed" | bc)
            log_info "Inserted: $total_inserted records, Rate: $actual_rate/sec"
        fi

        sleep $sleep_interval
    done

    local insert_end_time=$(get_timestamp_ms)
    local insert_duration=$((insert_end_time - start_time))
    local actual_rate=$(echo "scale=2; $total_inserted * 1000 / $insert_duration" | bc)

    log_info "Insert phase complete: $total_inserted records in ${insert_duration}ms ($actual_rate/sec)"

    # Wait for sync
    log_info "Waiting for all records to sync..."
    local attempt=0

    while [ $attempt -lt $MAX_WAIT_SECONDS ]; do
        local synced=$(starrocks_cmd "SELECT COUNT(*) FROM orders WHERE shipping_address LIKE '${test_marker}_%';" 2>/dev/null || echo "0")
        local lag=$((total_inserted - synced))

        log_info "Synced: $synced / $total_inserted (lag: $lag)"

        if [ "$synced" -ge "$total_inserted" ]; then
            break
        fi

        sleep 2
        ((attempt+=2))
    done

    local sync_end_time=$(get_timestamp_ms)
    local total_duration=$((sync_end_time - start_time))
    local sync_latency=$((sync_end_time - insert_end_time))

    log_info ""
    log_info "Results:"
    log_info "  Total records: $total_inserted"
    log_info "  Insert duration: ${insert_duration}ms"
    log_info "  Insert rate: $actual_rate records/sec"
    log_info "  Final sync latency: ${sync_latency}ms"
    log_info "  Total duration: ${total_duration}ms"
}

unlimited_load() {
    local rate=${1:-5}  # records per second per table

    log_header "Unlimited Data Loading - All Tables"
    log_info "Rate: ${rate} records/sec (per table). Press Ctrl+C to stop."
    echo ""

    local test_marker="unlimited_$(date +%s)"
    local start_time=$(get_timestamp_ms)
    local sleep_interval=$(echo "scale=4; 1 / $rate" | bc)

    # Counters for each table
    local orders_count=0
    local customers_count=0
    local products_count=0
    local order_items_count=0
    local inventory_count=0
    local total_count=0
    local batch_num=0

    # Get existing IDs for foreign keys
    local cust_ids=$(mysql_cmd "SELECT customer_id FROM customers LIMIT 100;")
    local prod_ids=$(mysql_cmd "SELECT product_id FROM products LIMIT 100;")

    # Trap Ctrl+C to show final stats
    trap 'show_unlimited_stats $start_time $orders_count $customers_count $products_count $order_items_count $inventory_count; exit 0' INT TERM

    log_info "Starting unlimited insert loop..."
    echo ""

    while true; do
        ((batch_num++))
        local batch_marker="${test_marker}_${batch_num}"

        # Insert customer
        local tier_idx=$((batch_num % 3))
        local tiers=("BRONZE" "SILVER" "GOLD")
        mysql_cmd "INSERT INTO customers (first_name, last_name, email, phone, registration_date, customer_tier, total_orders, total_spent)
                   VALUES ('Unlimited', 'User_$batch_num', 'unlimited_${batch_marker}@example.com', '555-${batch_num}', CURDATE(), '${tiers[$tier_idx]}', 0, 0.00);" 2>/dev/null && ((customers_count++))

        # Insert product
        local price=$(printf "%.2f" $(echo "$RANDOM / 10" | bc -l))
        local categories=("Electronics" "Clothing" "Home" "Sports" "Books")
        local cat_idx=$((batch_num % 5))
        mysql_cmd "INSERT INTO products (sku, product_name, category, price, stock_quantity, is_active)
                   VALUES ('UNLIM_${batch_marker}', 'Unlimited Product $batch_num', '${categories[$cat_idx]}', $price, $((100 + RANDOM % 500)), true);" 2>/dev/null && ((products_count++))

        # Insert order
        local cust_id=$(echo "$cust_ids" | head -n $(( (batch_num % 100) + 1 )) | tail -n 1)
        [ -z "$cust_id" ] && cust_id=1
        local amount=$(printf "%.2f" $(echo "$RANDOM / 10" | bc -l))
        local statuses=("PENDING" "PROCESSING" "SHIPPED" "DELIVERED")
        local stat_idx=$((batch_num % 4))
        mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
                   VALUES ($cust_id, '${statuses[$stat_idx]}', $amount, 'unlimited_addr_${batch_marker}');" 2>/dev/null && ((orders_count++))

        # Get last order ID for order_items
        local order_id=$(mysql_cmd "SELECT order_id FROM orders WHERE shipping_address='unlimited_addr_${batch_marker}' LIMIT 1;")

        # Insert order item
        local prod_id=$(echo "$prod_ids" | head -n $(( (batch_num % 100) + 1 )) | tail -n 1)
        [ -z "$prod_id" ] && prod_id=1
        local qty=$((1 + RANDOM % 5))
        local unit_price=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))
        local total_price=$(printf "%.2f" $(echo "$qty * $unit_price" | bc -l))
        if [ -n "$order_id" ]; then
            mysql_cmd "INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
                       VALUES ($order_id, $prod_id, $qty, $unit_price, $total_price);" 2>/dev/null && ((order_items_count++))
        fi

        # Insert inventory movement
        local inv_qty=$((10 + RANDOM % 100))
        local types=("IN" "OUT" "ADJUSTMENT")
        local type_idx=$((batch_num % 3))
        mysql_cmd "INSERT INTO inventory_movements (product_id, movement_type, quantity, reference_id, notes)
                   VALUES ($prod_id, '${types[$type_idx]}', $inv_qty, NULL, 'Unlimited test ${batch_marker}');" 2>/dev/null && ((inventory_count++))

        total_count=$((orders_count + customers_count + products_count + order_items_count + inventory_count))

        # Show progress every 50 batches
        if [ $((batch_num % 50)) -eq 0 ]; then
            local current_time=$(get_timestamp_ms)
            local elapsed_sec=$(echo "scale=2; ($current_time - $start_time) / 1000" | bc)
            local rate_actual=$(echo "scale=2; $total_count / $elapsed_sec" | bc)

            echo -e "${CYAN}[PROGRESS]${NC} Batch: $batch_num | Total: $total_count records | Rate: ${rate_actual}/sec"
            echo -e "           orders=$orders_count, customers=$customers_count, products=$products_count, items=$order_items_count, inventory=$inventory_count"
        fi

        sleep $sleep_interval
    done
}

show_unlimited_stats() {
    local start_time=$1
    local orders=$2
    local customers=$3
    local products=$4
    local items=$5
    local inventory=$6

    local end_time=$(get_timestamp_ms)
    local duration_ms=$((end_time - start_time))
    local duration_sec=$(echo "scale=2; $duration_ms / 1000" | bc)
    local total=$((orders + customers + products + items + inventory))
    local rate=$(echo "scale=2; $total / $duration_sec" | bc)

    echo ""
    log_header "Unlimited Load Complete"
    log_info "Duration: ${duration_sec}s"
    log_info "Total records inserted: $total"
    log_info "  - orders:            $orders"
    log_info "  - customers:         $customers"
    log_info "  - products:          $products"
    log_info "  - order_items:       $items"
    log_info "  - inventory:         $inventory"
    log_info "Average rate: ${rate} records/sec"
    echo ""
    log_info "Waiting for final sync..."
    sleep 5
    show_current_counts
}

load_all_tables() {
    local count=${1:-10}

    log_header "Load All Tables ($count records each)"

    local test_marker="load_$(date +%s)"
    local start_time=$(get_timestamp_ms)

    log_info "Loading $count records into each table..."

    # Load customers
    log_info "  Loading customers..."
    for i in $(seq 1 $count); do
        local tier_idx=$((i % 3))
        local tiers=("BRONZE" "SILVER" "GOLD")
        mysql_cmd "INSERT INTO customers (first_name, last_name, email, phone, registration_date, customer_tier, total_orders, total_spent)
                   VALUES ('Load', 'User_${test_marker}_$i', 'load_${test_marker}_${i}@example.com', '555-${i}000', CURDATE(), '${tiers[$tier_idx]}', $i, $((i * 100)).00);"
    done

    # Load products
    log_info "  Loading products..."
    for i in $(seq 1 $count); do
        local price=$(printf "%.2f" $(echo "$RANDOM / 10" | bc -l))
        local categories=("Electronics" "Clothing" "Home" "Sports" "Books")
        local cat_idx=$((i % 5))
        mysql_cmd "INSERT INTO products (sku, product_name, category, price, stock_quantity, is_active)
                   VALUES ('LOAD_${test_marker}_$i', 'Load Product ${test_marker}_$i', '${categories[$cat_idx]}', $price, $((100 + RANDOM % 500)), true);"
    done

    # Get existing customers and products for orders
    local cust_ids=$(mysql_cmd "SELECT customer_id FROM customers LIMIT 10;")
    local prod_ids=$(mysql_cmd "SELECT product_id FROM products LIMIT 10;")

    # Load orders
    log_info "  Loading orders..."
    for i in $(seq 1 $count); do
        local cust_id=$(echo "$cust_ids" | head -n $(( (i % 10) + 1 )) | tail -n 1)
        local amount=$(printf "%.2f" $(echo "$RANDOM / 10" | bc -l))
        local statuses=("PENDING" "PROCESSING" "SHIPPED" "DELIVERED")
        local stat_idx=$((i % 4))
        mysql_cmd "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address)
                   VALUES ($cust_id, '${statuses[$stat_idx]}', $amount, 'load_addr_${test_marker}_$i');"
    done

    # Get order IDs for order items
    local order_ids=$(mysql_cmd "SELECT order_id FROM orders WHERE shipping_address LIKE 'load_addr_${test_marker}_%' LIMIT $count;")

    # Load order items
    log_info "  Loading order_items..."
    local order_num=1
    for order_id in $order_ids; do
        local prod_id=$(echo "$prod_ids" | head -n $(( (order_num % 10) + 1 )) | tail -n 1)
        local qty=$((1 + RANDOM % 5))
        local unit_price=$(printf "%.2f" $(echo "$RANDOM / 100" | bc -l))
        local total_price=$(printf "%.2f" $(echo "$qty * $unit_price" | bc -l))
        mysql_cmd "INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
                   VALUES ($order_id, $prod_id, $qty, $unit_price, $total_price);"
        ((order_num++))
    done

    # Load inventory movements
    log_info "  Loading inventory_movements..."
    local prod_num=1
    for prod_id in $prod_ids; do
        local qty=$((10 + RANDOM % 100))
        local types=("IN" "OUT" "ADJUSTMENT")
        local type_idx=$((prod_num % 3))
        mysql_cmd "INSERT INTO inventory_movements (product_id, movement_type, quantity, reference_id, notes)
                   VALUES ($prod_id, '${types[$type_idx]}', $qty, NULL, 'Load test ${test_marker}_$prod_num');"
        ((prod_num++))
    done

    local insert_time=$(get_timestamp_ms)
    local insert_duration=$((insert_time - start_time))
    log_info "All inserts completed in ${insert_duration}ms"

    # Wait for sync
    log_info "Waiting for CDC sync..."
    sleep 5

    # Show final counts
    show_current_counts
}

cleanup_test_data() {
    log_header "Cleanup Test Data"

    log_info "Removing test data from MySQL..."

    # Clean order_items first (foreign key to orders)
    log_info "  Cleaning order_items..."
    mysql_cmd "DELETE oi FROM order_items oi
               INNER JOIN orders o ON oi.order_id = o.order_id
               WHERE o.order_status IN ('TEST', 'BATCH', 'TO_DELETE', 'CONTINUOUS', 'MULTI_TEST', 'PENDING', 'PROCESSING', 'SHIPPED', 'DELIVERED')
               AND (o.shipping_address LIKE 'latency_test_%'
                    OR o.shipping_address LIKE 'batch_%'
                    OR o.shipping_address LIKE 'delete_test_%'
                    OR o.shipping_address LIKE 'continuous_%'
                    OR o.shipping_address LIKE 'multi_addr_%'
                    OR o.shipping_address LIKE 'load_addr_%');" 2>/dev/null || true

    # Clean orders
    log_info "  Cleaning orders..."
    mysql_cmd "DELETE FROM orders WHERE order_status IN ('TEST', 'BATCH', 'TO_DELETE', 'CONTINUOUS', 'MULTI_TEST', 'PENDING', 'PROCESSING', 'SHIPPED', 'DELIVERED')
               AND (shipping_address LIKE 'latency_test_%'
               OR shipping_address LIKE 'batch_%'
               OR shipping_address LIKE 'delete_test_%'
               OR shipping_address LIKE 'continuous_%'
               OR shipping_address LIKE 'multi_addr_%'
               OR shipping_address LIKE 'load_addr_%'
               OR shipping_address LIKE 'unlimited_addr_%');"

    # Clean customers
    log_info "  Cleaning customers..."
    mysql_cmd "DELETE FROM customers WHERE email LIKE 'test_%@example.com' OR email LIKE 'load_%@example.com' OR email LIKE 'unlimited_%@example.com';"

    # Clean products
    log_info "  Cleaning products..."
    mysql_cmd "DELETE FROM products WHERE sku LIKE 'SKU_%' OR sku LIKE 'LOAD_%' OR sku LIKE 'UNLIM_%';"

    # Clean inventory movements
    log_info "  Cleaning inventory_movements..."
    mysql_cmd "DELETE FROM inventory_movements WHERE notes LIKE 'Test movement %' OR notes LIKE 'Load test %' OR notes LIKE 'Unlimited test %';"

    log_info "Cleanup complete! Waiting for CDC sync..."
    sleep 5
    show_current_counts
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  single       Test single insert latency (orders table)"
    echo "  multi        Test multi-table insert latency (all 5 tables)"
    echo "  batch [n]    Test batch insert latency (default: 100 records)"
    echo "  update       Test update latency"
    echo "  delete       Test delete latency"
    echo "  all          Run all latency tests (single + multi + batch + update)"
    echo "  load [n]     Load data into ALL tables (default: 10 records each)"
    echo "  unlimited [rate]          Unlimited loading into ALL tables until Ctrl+C (default: 5/sec)"
    echo "  continuous [duration] [rate]  Continuous load test (default: 30s, 5/sec)"
    echo "  counts       Show current data counts for all tables"
    echo "  cleanup      Remove test data from all tables"
    echo ""
    echo "Tables tested: orders, customers, products, order_items, inventory_movements"
    echo ""
    echo "Examples:"
    echo "  $0 all                    # Run all latency tests"
    echo "  $0 multi                  # Test insert latency across all tables"
    echo "  $0 load 50                # Load 50 records into each table"
    echo "  $0 unlimited 10           # Unlimited loading at 10 records/sec (Ctrl+C to stop)"
    echo "  $0 batch 500              # Insert 500 orders records"
    echo "  $0 continuous 60 10       # 60 seconds at 10 records/sec"
}

main() {
    local cmd=${1:-all}

    case $cmd in
        single)
            test_single_insert
            ;;
        multi)
            test_all_tables_insert
            ;;
        batch)
            test_batch_insert ${2:-$BATCH_SIZE}
            ;;
        update)
            test_update_latency
            ;;
        delete)
            test_delete_latency
            ;;
        all)
            show_current_counts
            test_single_insert
            test_all_tables_insert
            test_batch_insert 50
            test_update_latency
            show_current_counts
            ;;
        load)
            load_all_tables ${2:-10}
            ;;
        unlimited)
            unlimited_load ${2:-5}
            ;;
        continuous)
            continuous_load ${2:-30} ${3:-5}
            ;;
        counts)
            show_current_counts
            ;;
        cleanup)
            cleanup_test_data
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
