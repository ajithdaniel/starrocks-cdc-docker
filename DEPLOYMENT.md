# MySQL to StarRocks Shared-Data CDC - Deployment Guide

Complete step-by-step guide to deploy the MySQL to StarRocks CDC pipeline using Docker.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Detailed Setup](#detailed-setup)
4. [Verification](#verification)
5. [Testing CDC](#testing-cdc)
6. [Monitoring](#monitoring)
7. [Troubleshooting](#troubleshooting)
8. [Production Considerations](#production-considerations)
9. [Cleanup](#cleanup)

---

## Prerequisites

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 16 GB | 32 GB |
| Disk | 20 GB | 50+ GB SSD |
| OS | Linux/macOS | Linux (Ubuntu 20.04+) |

### Software Requirements

1. **Docker** (20.10+)
   ```bash
   # Check version
   docker --version

   # Install on Ubuntu
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker $USER
   ```

2. **Docker Compose** (2.0+)
   ```bash
   # Check version
   docker-compose --version

   # Install (if not bundled with Docker)
   sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
   sudo chmod +x /usr/local/bin/docker-compose
   ```

3. **Python 3.8+** (for benchmark/monitor tools)
   ```bash
   python3 --version
   pip3 install mysql-connector-python
   ```

4. **MySQL Client** (optional, for direct access)
   ```bash
   # Ubuntu
   sudo apt-get install mysql-client

   # macOS
   brew install mysql-client
   ```

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/YOUR_USERNAME/starrocks-cdc-docker.git
cd starrocks-cdc-docker

# 2. Start all services
docker-compose up -d

# 3. Wait for initialization (2-3 minutes)
docker logs -f cdc-setup

# 4. Verify CDC is working
./scripts/test-cdc-latency-docker.sh counts
```

---

## Detailed Setup

### Step 1: Clone and Configure

```bash
# Clone repository
git clone https://github.com/YOUR_USERNAME/starrocks-cdc-docker.git
cd starrocks-cdc-docker

# Review configuration files (optional)
cat config/fe.conf    # StarRocks Frontend config
cat config/cn.conf    # StarRocks Compute Node config
```

### Step 2: Start Infrastructure Services

Start services in order to ensure proper initialization:

```bash
# Start MinIO (object storage)
docker-compose up -d minio minio-init

# Wait for MinIO to be ready
docker-compose logs -f minio-init
# Should see: "MinIO bucket created successfully"
```

### Step 3: Start MySQL Source Database

```bash
# Start MySQL
docker-compose up -d mysql

# Wait for MySQL to be healthy
docker-compose ps mysql
# Should show "healthy" status

# Verify MySQL is working
docker exec -it mysql-source mysql -u cdc_user -pcdc_pass123 source_db -e "SHOW TABLES;"
```

Expected output:
```
+---------------------+
| Tables_in_source_db |
+---------------------+
| customers           |
| inventory_movements |
| order_items         |
| orders              |
| products            |
+---------------------+
```

### Step 4: Start StarRocks Cluster

```bash
# Start StarRocks Frontend
docker-compose up -d starrocks-fe

# Wait for FE to be healthy (may take 60-90 seconds)
docker-compose logs -f starrocks-fe
# Look for: "Fesystem is ready"

# Start StarRocks Compute Node
docker-compose up -d starrocks-cn

# Wait for CN to be healthy
docker-compose logs -f starrocks-cn
# Look for: "register to starrocks-fe success"
```

### Step 5: Start Flink CDC

```bash
# Start Flink JobManager
docker-compose up -d flink-jobmanager

# Start Flink TaskManager
docker-compose up -d flink-taskmanager

# Verify Flink is running
curl http://localhost:8081/overview
```

### Step 6: Initialize CDC Pipeline

```bash
# Start CDC setup container (creates tables and starts CDC jobs)
docker-compose up -d cdc-setup

# Monitor setup progress
docker logs -f cdc-setup
```

The setup script will:
1. Wait for all services to be healthy
2. Register CN node with FE
3. Create StarRocks database and tables
4. Submit Flink CDC jobs for all 5 tables

### Step 7: Verify All Services

```bash
# Check all containers are running
docker-compose ps

# Expected output:
# NAME                STATUS              PORTS
# cdc-setup           exited (0)
# flink-jobmanager    running             0.0.0.0:8081->8081/tcp
# flink-taskmanager   running
# minio               running (healthy)   0.0.0.0:9000-9001->9000-9001/tcp
# mysql-source        running (healthy)   0.0.0.0:3306->3306/tcp
# starrocks-cn        running (healthy)   0.0.0.0:8040->8040/tcp
# starrocks-fe        running (healthy)   0.0.0.0:8030->8030/tcp, 0.0.0.0:9030->9030/tcp
```

---

## Verification

### Verify StarRocks Cluster

```bash
# Connect to StarRocks
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root

# Check compute nodes
SHOW COMPUTE NODES;
# Should show 1 CN node with Alive = true

# Check database and tables
USE cdc_db;
SHOW TABLES;
# Should show: orders, customers, products, order_items, inventory_movements

# Check table structure
DESC orders;
```

### Verify Flink CDC Jobs

1. **Open Flink Dashboard**: http://localhost:8081

2. **Check Running Jobs**: Should see 5 jobs running (one per table)

3. **Via CLI**:
   ```bash
   curl http://localhost:8081/jobs/overview
   ```

### Verify Data Sync

```bash
# Check row counts in both databases
./scripts/test-cdc-latency-docker.sh counts
```

Expected output:
```
=== Current Data Counts ===
Table               MySQL       StarRocks
orders              50          50
customers           20          20
products            30          30
order_items         100         100
inventory_movements 25          25
```

---

## Testing CDC

### Quick Latency Test

```bash
# Single insert test
./scripts/test-cdc-latency-docker.sh single

# Multi-table insert test
./scripts/test-cdc-latency-docker.sh multi

# Batch insert test (100 records)
./scripts/test-cdc-latency-docker.sh batch 100
```

### Load Testing

```bash
# Load data into all tables
./scripts/test-cdc-latency-docker.sh load 500

# Continuous load test (60 seconds)
./scripts/test-cdc-latency-docker.sh continuous 60 10

# Unlimited loading (Ctrl+C to stop)
./scripts/test-cdc-latency-docker.sh unlimited 20
```

### Python Benchmark

```bash
# Install dependency
pip3 install mysql-connector-python

# Run parallel benchmark
python3 scripts/cdc-benchmark.py parallel -d 60 -w 4

# Run burst test
python3 scripts/cdc-benchmark.py burst -n 1000
```

### Python Monitor

```bash
# Real-time dashboard
python3 scripts/cdc-monitor.py

# Simple output
python3 scripts/cdc-monitor.py --mode simple

# JSON output (for integration)
python3 scripts/cdc-monitor.py --mode json
```

---

## Monitoring

### Service URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Flink Dashboard | http://localhost:8081 | - |
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin123 |
| StarRocks FE HTTP | http://localhost:8030 | - |

### StarRocks Monitoring Queries

```sql
-- Connect to StarRocks
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root cdc_db

-- Check CN status
SHOW COMPUTE NODES;

-- Check table data size
SHOW DATA FROM cdc_db;

-- Check compaction status
SELECT * FROM information_schema.be_cloud_native_compactions;

-- Check running transactions
SHOW PROC '/transactions/cdc_db/running';

-- Check load history
SHOW LOAD FROM cdc_db;
```

### Log Locations

```bash
# StarRocks FE logs
docker logs starrocks-fe
docker exec starrocks-fe tail -f /opt/starrocks/fe/log/fe.log

# StarRocks CN logs
docker logs starrocks-cn
docker exec starrocks-cn tail -f /opt/starrocks/cn/log/cn.log

# Flink logs
docker logs flink-jobmanager
docker logs flink-taskmanager

# MySQL logs
docker logs mysql-source
```

---

## Troubleshooting

### Common Issues

#### 1. CN Not Registering with FE

**Symptoms**: `SHOW COMPUTE NODES` returns empty or shows CN as not alive

**Solution**:
```bash
# Manually add CN
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root -e \
  "ALTER SYSTEM ADD COMPUTE NODE 'starrocks-cn:9050';"

# Verify
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root -e \
  "SHOW COMPUTE NODES;"
```

#### 2. Flink Jobs Failing

**Symptoms**: Jobs show as FAILED in Flink dashboard

**Solution**:
```bash
# Check Flink logs
docker logs flink-taskmanager

# Common fixes:
# 1. Increase task slots in docker-compose.yml
# 2. Increase memory for taskmanager
# 3. Check connector JARs are present
ls -la flink-cdc/lib/
```

#### 3. CDC Not Syncing Data

**Symptoms**: Data inserted in MySQL doesn't appear in StarRocks

**Diagnosis**:
```bash
# 1. Check Flink jobs are running
curl http://localhost:8081/jobs/overview

# 2. Check MySQL binlog is enabled
docker exec mysql-source mysql -u root -proot123 -e "SHOW MASTER STATUS;"

# 3. Check StarRocks load errors
docker exec -it starrocks-fe mysql -h 127.0.0.1 -P 9030 -u root cdc_db -e \
  "SHOW LOAD WARNINGS;"

# 4. Test manual insert
./scripts/test-cdc-latency-docker.sh single
```

#### 4. MinIO Connection Issues

**Symptoms**: StarRocks FE fails to start or shows S3 errors

**Solution**:
```bash
# Check MinIO is healthy
curl http://localhost:9000/minio/health/live

# Check bucket exists
docker run --rm --network starrocks-cdc-docker_starrocks-net \
  minio/mc alias set myminio http://minio:9000 minioadmin minioadmin123 && \
  mc ls myminio/starrocks
```

#### 5. Memory Issues

**Symptoms**: Containers keep restarting, OOM errors in logs

**Solution**:
```bash
# Check container memory usage
docker stats

# Increase memory limits in docker-compose.yml
# Edit deploy.resources.limits.memory for affected service

# Restart affected service
docker-compose up -d <service-name>
```

### Reset Everything

```bash
# Stop all services and remove volumes
docker-compose down -v

# Remove all containers
docker-compose rm -f

# Start fresh
docker-compose up -d
```

---

## Production Considerations

### Security

1. **Change default passwords**:
   ```yaml
   # docker-compose.yml
   MYSQL_ROOT_PASSWORD: <strong-password>
   MINIO_ROOT_PASSWORD: <strong-password>
   ```

2. **Enable StarRocks authentication**:
   ```sql
   -- Connect to StarRocks
   SET PASSWORD FOR 'root' = PASSWORD('your-password');
   CREATE USER 'cdc_user' IDENTIFIED BY 'password';
   GRANT ALL ON cdc_db.* TO 'cdc_user';
   ```

3. **Update Flink CDC configs** with credentials

### High Availability

1. **Multiple FE nodes** (for metadata HA):
   ```yaml
   starrocks-fe-follower:
     image: starrocks/fe-ubuntu:3.3.0
     # ... similar config
   ```

2. **Multiple CN nodes** (for compute scaling):
   ```yaml
   starrocks-cn-2:
     image: starrocks/cn-ubuntu:3.3.0
     # ... similar config
   ```

3. **Flink HA** with ZooKeeper:
   ```yaml
   zookeeper:
     image: zookeeper:3.8
   ```

### Performance Tuning

1. **Increase Flink parallelism**:
   ```yaml
   environment:
     - FLINK_PROPERTIES=
       parallelism.default: 4
       taskmanager.numberOfTaskSlots: 16
   ```

2. **Tune StarRocks for CDC**:
   ```properties
   # cn.conf
   compact_threads = 8
   transaction_publish_version_worker_count = 16
   ```

3. **Increase buffer sizes**:
   ```sql
   -- In Flink CDC SQL
   'sink.buffer-flush.interval-ms' = '2000',
   'sink.buffer-flush.max-rows' = '10000'
   ```

### Backup Strategy

1. **MySQL backups**:
   ```bash
   docker exec mysql-source mysqldump -u root -proot123 source_db > backup.sql
   ```

2. **MinIO data** (StarRocks data files):
   ```bash
   # Use MinIO client for backup
   mc mirror myminio/starrocks /backup/starrocks
   ```

3. **StarRocks metadata**:
   ```bash
   # Backup FE metadata
   docker cp starrocks-fe:/opt/starrocks/fe/meta ./fe-meta-backup
   ```

---

## Cleanup

### Stop Services (Keep Data)

```bash
docker-compose stop
```

### Stop and Remove Containers (Keep Volumes)

```bash
docker-compose down
```

### Complete Cleanup (Remove Everything)

```bash
# Stop containers and remove volumes
docker-compose down -v

# Remove images
docker-compose down --rmi all

# Remove network
docker network rm starrocks-cdc-docker_starrocks-net

# Clean up test data only (keep services running)
./scripts/test-cdc-latency-docker.sh cleanup
```

---

## Architecture Reference

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Docker Network: starrocks-net                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐     ┌──────────────────┐     ┌───────────────────┐   │
│  │    MySQL     │     │   Flink Cluster  │     │    StarRocks      │   │
│  │   :3306      │────▶│                  │────▶│                   │   │
│  │              │     │  JobManager:8081 │     │  FE:8030,9030     │   │
│  │  source_db   │     │  TaskManager     │     │  CN:8040          │   │
│  │  - orders    │     │  (12 slots)      │     │                   │   │
│  │  - customers │     │                  │     │  cdc_db           │   │
│  │  - products  │     │  CDC Jobs (5)    │     │  - orders         │   │
│  │  - order_items     │  - mysql-cdc     │     │  - customers      │   │
│  │  - inventory │     │  - starrocks     │     │  - products       │   │
│  └──────────────┘     └──────────────────┘     │  - order_items    │   │
│                                                 │  - inventory      │   │
│  ┌──────────────┐                              │                   │   │
│  │    MinIO     │◀─────────────────────────────│  (Object Storage) │   │
│  │  :9000,9001  │                              └───────────────────┘   │
│  │              │                                                       │
│  │  starrocks/  │  ◀── Data files stored here                         │
│  └──────────────┘                                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

Data Flow:
1. Application writes to MySQL (binlog enabled)
2. Flink CDC reads MySQL binlog changes
3. Flink transforms and writes to StarRocks via Stream Load
4. StarRocks stores data in MinIO (shared-data mode)
5. Queries execute on CN nodes, reading from MinIO
```

---

## Support

- **Issues**: https://github.com/YOUR_USERNAME/starrocks-cdc-docker/issues
- **StarRocks Docs**: https://docs.starrocks.io/
- **Flink CDC Docs**: https://nightlies.apache.org/flink/flink-cdc-docs-master/
