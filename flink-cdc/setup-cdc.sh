#!/bin/bash
# =============================================================================
# CDC Setup Script
# Initializes StarRocks tables and starts Flink CDC pipeline
# =============================================================================

set -e

echo "=============================================="
echo "StarRocks CDC Setup Script"
echo "=============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# Install MySQL client
# =============================================================================
install_mysql_client() {
    log_info "Installing MySQL client..."
    apt-get update -qq && apt-get install -y -qq default-mysql-client > /dev/null 2>&1 || true
    log_info "MySQL client installed."
}

# Install MySQL client at startup
install_mysql_client

# =============================================================================
# Wait for StarRocks FE to be ready
# =============================================================================
wait_for_starrocks_fe() {
    log_info "Waiting for StarRocks FE to be ready..."
    
    max_attempts=60
    attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://starrocks-fe:8030/api/health" > /dev/null 2>&1; then
            log_info "StarRocks FE is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_info "Attempt $attempt/$max_attempts - StarRocks FE not ready yet..."
        sleep 5
    done
    
    log_error "StarRocks FE did not become ready in time"
    return 1
}

# =============================================================================
# Wait for StarRocks CN to be registered
# =============================================================================
wait_for_starrocks_cn() {
    log_info "Waiting for StarRocks CN to be registered..."
    
    # First, add CN to cluster
    log_info "Adding CN node to cluster..."

    max_attempts=30
    attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Try to add CN (may already exist)
        mysql -h starrocks-fe -P 9030 -u root -e "ALTER SYSTEM ADD COMPUTE NODE 'starrocks-cn:9050';" 2>/dev/null || true
        
        # Check if CN is alive
        cn_status=$(mysql -h starrocks-fe -P 9030 -u root -N -e "SHOW COMPUTE NODES;" 2>/dev/null | grep -c "starrocks-cn" || echo "0")
        
        if [ "$cn_status" -ge "1" ]; then
            log_info "StarRocks CN is registered!"
            
            # Wait a bit more for CN to be fully ready
            sleep 10
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_info "Attempt $attempt/$max_attempts - CN not registered yet..."
        sleep 5
    done
    
    log_error "StarRocks CN did not register in time"
    return 1
}

# =============================================================================
# Wait for MySQL to be ready
# =============================================================================
wait_for_mysql() {
    log_info "Waiting for MySQL to be ready..."
    
    max_attempts=30
    attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if mysql -h mysql -P 3306 -u cdc_user -pcdc_pass123 -e "SELECT 1;" > /dev/null 2>&1; then
            log_info "MySQL is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_info "Attempt $attempt/$max_attempts - MySQL not ready yet..."
        sleep 5
    done
    
    log_error "MySQL did not become ready in time"
    return 1
}

# =============================================================================
# Create StarRocks tables
# =============================================================================
create_starrocks_tables() {
    log_info "Creating StarRocks tables..."
    
    mysql -h starrocks-fe -P 9030 -u root < /sql/starrocks-init.sql
    
    if [ $? -eq 0 ]; then
        log_info "StarRocks tables created successfully!"
    else
        log_error "Failed to create StarRocks tables"
        return 1
    fi
}

# =============================================================================
# Verify MySQL data
# =============================================================================
verify_mysql_data() {
    log_info "Verifying MySQL source data..."
    
    tables=("orders" "customers" "products" "order_items" "inventory_movements")
    
    for table in "${tables[@]}"; do
        count=$(mysql -h mysql -P 3306 -u cdc_user -pcdc_pass123 -N -e "SELECT COUNT(*) FROM source_db.$table;" 2>/dev/null)
        log_info "  - $table: $count rows"
    done
}

# =============================================================================
# Download Flink CDC dependencies
# =============================================================================
download_flink_cdc() {
    log_info "Downloading Flink CDC dependencies..."
    
    CDC_VERSION="3.1.0"
    FLINK_VERSION="1.18"
    
    CDC_DIR="/opt/flink-cdc"
    mkdir -p "$CDC_DIR/lib"
    
    # Download Flink CDC distribution
    if [ ! -f "$CDC_DIR/flink-cdc-$CDC_VERSION.tar.gz" ]; then
        log_info "Downloading Flink CDC $CDC_VERSION..."
        curl -L -o "$CDC_DIR/flink-cdc-$CDC_VERSION.tar.gz" \
            "https://github.com/apache/flink-cdc/releases/download/release-$CDC_VERSION/flink-cdc-$CDC_VERSION-bin.tar.gz" || {
            log_warn "Could not download Flink CDC. Will use SQL approach instead."
            return 1
        }
        
        tar -xzf "$CDC_DIR/flink-cdc-$CDC_VERSION.tar.gz" -C "$CDC_DIR"
    fi
    
    # Download MySQL CDC connector
    if [ ! -f "$CDC_DIR/lib/flink-sql-connector-mysql-cdc-$CDC_VERSION.jar" ]; then
        log_info "Downloading MySQL CDC connector..."
        curl -L -o "$CDC_DIR/lib/flink-sql-connector-mysql-cdc-$CDC_VERSION.jar" \
            "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-mysql-cdc/$CDC_VERSION/flink-sql-connector-mysql-cdc-$CDC_VERSION.jar" || {
            log_warn "Could not download MySQL CDC connector"
        }
    fi
    
    # Download StarRocks connector
    STARROCKS_CONNECTOR_VERSION="1.2.9"
    if [ ! -f "$CDC_DIR/lib/flink-connector-starrocks-$STARROCKS_CONNECTOR_VERSION.jar" ]; then
        log_info "Downloading StarRocks connector..."
        curl -L -o "$CDC_DIR/lib/flink-connector-starrocks-$STARROCKS_CONNECTOR_VERSION.jar" \
            "https://repo1.maven.org/maven2/com/starrocks/flink-connector-starrocks/$STARROCKS_CONNECTOR_VERSION/flink-connector-starrocks-$STARROCKS_CONNECTOR_VERSION.jar" || {
            log_warn "Could not download StarRocks connector"
        }
    fi
    
    log_info "Flink CDC dependencies downloaded!"
    return 0
}

# =============================================================================
# Wait for Flink JobManager to be ready
# =============================================================================
wait_for_flink() {
    log_info "Waiting for Flink JobManager to be ready..."

    max_attempts=60
    attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://flink-jobmanager:8081/overview" > /dev/null 2>&1; then
            log_info "Flink JobManager is ready!"
            sleep 5  # Extra time to ensure full startup
            return 0
        fi

        attempt=$((attempt + 1))
        log_info "Attempt $attempt/$max_attempts - Flink not ready yet..."
        sleep 5
    done

    log_error "Flink JobManager did not become ready in time"
    return 1
}

# =============================================================================
# Start CDC using Flink SQL
# =============================================================================
start_cdc_flink_sql() {
    log_info "Starting CDC using Flink SQL..."

    # Wait for Flink
    wait_for_flink

    # Check if SQL file exists
    if [ -f "/opt/flink-cdc/cdc-single-job.sql" ]; then
        log_info "Submitting single CDC job for all 5 tables..."

        # Copy connector JARs to Flink lib if not already there
        if [ -d "/opt/flink-cdc/lib" ]; then
            log_info "CDC connector JARs found in /opt/flink-cdc/lib"
        fi

        # Submit the SQL file to Flink SQL Client via REST API
        # Since we can't use interactive SQL client, we'll submit via embedded SQL gateway

        # Alternative: Use Flink SQL Gateway REST API or submit directly
        log_info "Submitting CDC jobs to Flink..."

        # Submit each table's CDC job separately using curl to Flink REST API
        # For now, let's use the SQL client in non-interactive mode

        cd /opt/flink-cdc

        # Submit the SQL script via Flink SQL client (if available in the image)
        if [ -f "/opt/flink/bin/sql-client.sh" ]; then
            log_info "Using Flink SQL Client to submit jobs..."

            # Run SQL client with the single-job script (Statement Set)
            /opt/flink/bin/sql-client.sh -l /opt/flink/lib/cdc -f /opt/flink-cdc/cdc-single-job.sql 2>&1 | tee /tmp/flink-sql-output.log &

            # Wait for job to be submitted
            sleep 30

            # Check if the single job is running
            jobs_count=$(curl -s http://flink-jobmanager:8081/jobs/overview | grep -o '"state":"RUNNING"' | wc -l)

            if [ "$jobs_count" -ge "1" ]; then
                log_info "CDC single-job submitted successfully! Syncing all 5 tables in 1 job."
            else
                log_warn "Jobs may not have started. Check Flink dashboard: http://localhost:8081"
                log_info "SQL Client output:"
                cat /tmp/flink-sql-output.log 2>/dev/null | tail -50
            fi
        else
            log_warn "Flink SQL Client not found. Please submit jobs manually."
            log_info "Run: docker exec -it flink-jobmanager /opt/flink/bin/sql-client.sh -l /opt/flink/lib/cdc"
        fi
    else
        log_warn "CDC SQL file not found at /opt/flink-cdc/cdc-single-job.sql"
    fi
}

# =============================================================================
# Display connection info
# =============================================================================
display_info() {
    echo ""
    echo "=============================================="
    echo "CDC Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Connection Information:"
    echo "----------------------"
    echo "MySQL (Source):"
    echo "  Host: localhost:3306"
    echo "  Database: source_db"
    echo "  User: cdc_user / cdc_pass123"
    echo ""
    echo "StarRocks (Target):"
    echo "  MySQL Protocol: localhost:9030"
    echo "  HTTP API: localhost:8030"
    echo "  Database: cdc_db"
    echo "  User: root (no password)"
    echo ""
    echo "Flink Dashboard:"
    echo "  URL: http://localhost:8081"
    echo ""
    echo "MinIO Console:"
    echo "  URL: http://localhost:9001"
    echo "  User: minioadmin / minioadmin123"
    echo ""
    echo "Quick Test Commands:"
    echo "-------------------"
    echo "# Connect to MySQL source:"
    echo "mysql -h localhost -P 3306 -u cdc_user -pcdc_pass123 source_db"
    echo ""
    echo "# Connect to StarRocks:"
    echo "mysql -h localhost -P 9030 -u root cdc_db"
    echo ""
    echo "# Insert test data in MySQL:"
    echo "INSERT INTO orders (customer_id, order_status, total_amount) VALUES (1, 'NEW', 99.99);"
    echo ""
    echo "# Check CDC sync in StarRocks:"
    echo "SELECT * FROM orders ORDER BY order_id DESC LIMIT 5;"
    echo ""
}

# =============================================================================
# Main execution
# =============================================================================
main() {
    log_info "Starting CDC setup..."
    
    # Wait for all services
    wait_for_starrocks_fe
    wait_for_mysql
    wait_for_starrocks_cn
    
    # Verify MySQL data
    verify_mysql_data
    
    # Create StarRocks tables
    create_starrocks_tables
    
    # Try to download Flink CDC
    # download_flink_cdc || log_warn "Flink CDC download skipped"
    
    # Start CDC (using SQL approach as fallback)
    start_cdc_flink_sql
    
    # Display connection info
    display_info
    
    log_info "Setup complete! The container will now keep running..."
    
    # Keep container running
    tail -f /dev/null
}

# Run main function
main
