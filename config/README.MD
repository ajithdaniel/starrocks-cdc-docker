# StarRocks CDC Pipeline - Shared-Data Mode

Complete Docker-based implementation for Change Data Capture (CDC) from MySQL to StarRocks running in shared-data mode with MinIO as object storage.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CDC Pipeline Architecture                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────┐      ┌──────────────┐      ┌─────────────────────────────┐   │
│  │  MySQL   │      │  Flink CDC   │      │   StarRocks (Shared-Data)   │   │
│  │ (Source) │─────▶│   Pipeline   │─────▶│                             │   │
│  │          │      │              │      │  ┌─────┐    ┌────────────┐  │   │
│  │ Binlog   │      │ • Snapshot   │      │  │ FE  │───▶│   MinIO    │  │   │
│  │ enabled  │      │ • CDC Stream │      │  └──┬──┘    │  (S3 API)  │  │   │
│  └──────────┘      └──────────────┘      │     │       └────────────┘  │   │
│                                          │  ┌──▼──┐          ▲         │   │
│                                          │  │ CN  │──────────┘         │   │
│                                          │  │     │    (Object Store)  │   │
│                                          │  └─────┘                    │   │
│                                          └─────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Service | Description | Ports |
|---------|-------------|-------|
| MySQL | Source database with binlog enabled | 3306 |
| MinIO | S3-compatible object storage | 9000, 9001 (console) |
| StarRocks FE | Frontend - query planning, metadata | 8030, 9030 |
| StarRocks CN | Compute Node - stateless query execution | 8040 |
| Flink JobManager | CDC job orchestration (Flink 1.20) | 8081 |
| Flink TaskManager | CDC job execution (12 task slots) | - |

## Tables Replicated

| Table | Description | Primary Key |
|-------|-------------|-------------|
| orders | Customer orders | order_id |
| customers | Customer profiles | customer_id |
| products | Product catalog | product_id |
| order_items | Order line items | item_id |
| inventory_movements | Stock movements | movement_id |

## Quick Start

### 1. Start the Stack

```bash
cd starrocks-cdc-docker

# Start all services
docker-compose up -d

# Watch logs
docker-compose logs -f

# Check service status
docker-compose ps
```

### 2. Wait for Initialization

The setup container will:
1. Wait for all services to be healthy
2. Register CN node with FE
3. Create StarRocks tables
4. Start Flink CDC jobs for all 5 tables

```bash
# Check setup progress
docker logs -f cdc-setup
```

### 3. Verify Setup

```bash
# Connect to MySQL source
docker exec -it mysql-source mysql -u cdc_user -pcdc_pass123 source_db

# Check source data
SELECT COUNT(*) FROM orders;
SELECT COUNT(*) FROM customers;

# Connect to StarRocks
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root cdc_db

# Check cluster status
SHOW COMPUTE NODES;
SHOW TABLES;
```

## Starting CDC Pipeline

### Automatic Setup (Recommended)

CDC jobs start automatically via the `cdc-setup` container using Flink SQL. The setup script:
1. Waits for Flink JobManager to be ready
2. Submits CDC jobs for all 5 tables
3. Uses `flink-cdc/cdc-all-tables-full.sql`

### Manual Flink SQL Client

```bash
# Enter Flink container
docker exec -it flink-jobmanager bash

# Start SQL client with CDC connectors
/opt/flink/bin/sql-client.sh -l /opt/flink/lib/cdc

# Run CDC job for single table
# Copy contents from flink-cdc/cdc-orders.sql

# Or run all tables
# Copy contents from flink-cdc/cdc-all-tables-full.sql
```

### Connector JARs (Pre-installed)

The following connectors are included in `flink-cdc/lib/`:
- `flink-sql-connector-mysql-cdc-3.2.1.jar` - MySQL CDC connector
- `flink-connector-starrocks-1.2.12_flink-1.20.jar` - StarRocks sink
- `mysql-connector-java-8.0.28.jar` - MySQL JDBC driver

## Testing CDC

### Bash Test Script

```bash
# Make script executable
chmod +x scripts/test-cdc-latency-docker.sh

# Show help
./scripts/test-cdc-latency-docker.sh help

# Run single insert test with latency measurement
./scripts/test-cdc-latency-docker.sh single

# Run multi-table insert test (all 5 tables)
./scripts/test-cdc-latency-docker.sh multi

# Run batch insert test
./scripts/test-cdc-latency-docker.sh batch

# Load test data (default 100 records per table)
./scripts/test-cdc-latency-docker.sh load 500

# Unlimited data loading (runs until Ctrl+C)
./scripts/test-cdc-latency-docker.sh unlimited

# Check row counts
./scripts/test-cdc-latency-docker.sh counts

# Cleanup test data
./scripts/test-cdc-latency-docker.sh cleanup
```

### Python Benchmark Tool

For parallel performance testing:

```bash
# Install dependencies
pip install mysql-connector-python

# Run parallel benchmark (60 seconds, 4 workers)
python scripts/cdc-benchmark.py parallel -d 60 -w 4

# Run per-table sequential test
python scripts/cdc-benchmark.py per-table -n 100

# Run burst test (rapid inserts)
python scripts/cdc-benchmark.py burst -n 1000

# Run unlimited benchmark until Ctrl+C
python scripts/cdc-benchmark.py unlimited -w 8

# Show help
python scripts/cdc-benchmark.py --help
```

### Python Monitor Tool

For real-time latency monitoring:

```bash
# Start dashboard monitor (default)
python scripts/cdc-monitor.py

# Simple output mode
python scripts/cdc-monitor.py --mode simple

# JSON output for integration
python scripts/cdc-monitor.py --mode json

# Single status check
python scripts/cdc-monitor.py --mode status

# Custom probe interval (seconds)
python scripts/cdc-monitor.py --interval 2

# Show help
python scripts/cdc-monitor.py --help
```

### Manual Testing

```bash
# 1. Insert in MySQL
docker exec -it mysql-source mysql -u cdc_user -pcdc_pass123 source_db -e \
  "INSERT INTO orders (customer_id, order_status, total_amount) VALUES (1, 'NEW', 199.99);"

# 2. Wait 10-15 seconds for sync

# 3. Check in StarRocks
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root cdc_db -e \
  "SELECT * FROM orders ORDER BY order_id DESC LIMIT 5;"
```

## Monitoring

### Flink Dashboard
- URL: http://localhost:8081
- View running jobs, checkpoints, metrics
- 5 CDC jobs should be running (one per table)

### MinIO Console
- URL: http://localhost:9001
- Credentials: minioadmin / minioadmin123
- Check StarRocks data files in `starrocks` bucket

### StarRocks Metrics
```sql
-- Check CN status
SHOW COMPUTE NODES;

-- Check compaction status (v3.2+)
SELECT * FROM information_schema.be_cloud_native_compactions;

-- Check running transactions
SHOW PROC '/transactions/cdc_db/running';

-- Table statistics
SHOW DATA FROM cdc_db;
```

## Configuration Tuning

### For High-Frequency CDC Writes

Edit `config/cn.conf`:
```properties
# Increase compaction threads
compact_threads = 8

# Increase transaction workers
transaction_publish_version_worker_count = 16

# Adjust primary key index memory
l0_max_mem_usage = 209715200
```

Edit `config/fe.conf`:
```properties
# Increase slowdown threshold
lake_ingest_slowdown_threshold = 200

# Increase compaction score limit
lake_compaction_score_upper_bound = 4000
```

### For Large Tables

```sql
-- Create table with more buckets
CREATE TABLE large_orders (...)
PRIMARY KEY (order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 16
PROPERTIES (
    "enable_persistent_index" = "true",
    "persistent_index_type" = "CLOUD_NATIVE"
);
```

## Troubleshooting

### CN Not Registering

```bash
# Manually add CN (use port 9050 - the heartbeat port from cn.conf)
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root -e \
  "ALTER SYSTEM ADD COMPUTE NODE 'starrocks-cn:9050';"

# Check status
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root -e \
  "SHOW COMPUTE NODES;"
```

### CDC Not Syncing

1. Check Flink job status at http://localhost:8081 (should show 5 running jobs)
2. Check MySQL binlog:
   ```sql
   SHOW MASTER STATUS;
   SHOW BINARY LOGS;
   ```
3. Check StarRocks load errors:
   ```sql
   SHOW LOAD WARNINGS;
   ```

### MinIO Connection Issues

```bash
# Test MinIO connectivity
docker exec starrocks-fe curl http://minio:9000/minio/health/live

# Check bucket exists
docker exec minio-init mc ls myminio/starrocks
```

### Memory Issues

```bash
# Increase CN memory
docker-compose down
# Edit docker-compose.yml, add to starrocks-cn:
#   deploy:
#     resources:
#       limits:
#         memory: 8G
docker-compose up -d
```

## Cleanup

```bash
# Stop all services
docker-compose down

# Remove all data (volumes)
docker-compose down -v

# Remove images
docker-compose down --rmi all
```

## File Structure

```
starrocks-cdc-docker/
├── docker-compose.yml              # Main orchestration (Flink 1.20)
├── config/
│   ├── fe.conf                     # StarRocks FE configuration
│   ├── cn.conf                     # StarRocks CN configuration
│   └── README.MD                   # This file
├── scripts/
│   ├── mysql-init.sql              # MySQL schema and sample data
│   ├── starrocks-init.sql          # StarRocks table definitions
│   ├── test-cdc-latency-docker.sh  # Bash testing script
│   ├── cdc-benchmark.py            # Python parallel benchmark tool
│   └── cdc-monitor.py              # Python real-time monitor
└── flink-cdc/
    ├── setup-cdc.sh                # Initialization script
    ├── cdc-orders.sql              # Single table CDC job
    ├── cdc-all-tables-full.sql     # All 5 tables CDC jobs
    └── lib/
        ├── flink-connector-starrocks-1.2.12_flink-1.20.jar
        ├── flink-sql-connector-mysql-cdc-3.2.1.jar
        └── mysql-connector-java-8.0.28.jar
```

## References

- [StarRocks Shared-Data Documentation](https://docs.starrocks.io/docs/deployment/shared_data/)
- [StarRocks Primary Key Tables](https://docs.starrocks.io/docs/table_design/table_types/primary_key_table/)
- [Flink CDC Documentation](https://nightlies.apache.org/flink/flink-cdc-docs-master/)
- [StarRocks Flink Connector](https://docs.starrocks.io/docs/loading/Flink-connector-starrocks/)
