#!/usr/bin/env python3
"""
CDC Benchmark Script - Parallel Load Testing for MySQL to StarRocks CDC Pipeline

Features:
- Multi-threaded parallel inserts across all tables
- Real-time throughput and latency monitoring
- Configurable load patterns (steady, burst, ramp-up)
- CDC sync verification and lag measurement
- Comprehensive statistics and reporting
"""

import argparse
import concurrent.futures
import json
import mysql.connector
import os
import random
import signal
import string
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional, Tuple

# =============================================================================
# Configuration
# =============================================================================

MYSQL_CONFIG = {
    'host': os.getenv('MYSQL_HOST', 'localhost'),
    'port': int(os.getenv('MYSQL_PORT', 3306)),
    'user': os.getenv('MYSQL_USER', 'cdc_user'),
    'password': os.getenv('MYSQL_PASSWORD', 'cdc_pass123'),
    'database': os.getenv('MYSQL_DATABASE', 'source_db'),
}

STARROCKS_CONFIG = {
    'host': os.getenv('STARROCKS_HOST', 'localhost'),
    'port': int(os.getenv('STARROCKS_PORT', 9030)),
    'user': os.getenv('STARROCKS_USER', 'root'),
    'password': os.getenv('STARROCKS_PASSWORD', ''),
    'database': os.getenv('STARROCKS_DATABASE', 'cdc_db'),
}

TABLES = ['orders', 'customers', 'products', 'order_items', 'inventory_movements']

# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class Stats:
    """Thread-safe statistics collector"""
    inserts: Dict[str, int] = field(default_factory=lambda: {t: 0 for t in TABLES})
    errors: Dict[str, int] = field(default_factory=lambda: {t: 0 for t in TABLES})
    latencies: List[float] = field(default_factory=list)
    start_time: float = 0
    end_time: float = 0
    lock: threading.Lock = field(default_factory=threading.Lock)

    def record_insert(self, table: str, latency_ms: float):
        with self.lock:
            self.inserts[table] += 1
            self.latencies.append(latency_ms)

    def record_error(self, table: str):
        with self.lock:
            self.errors[table] += 1

    def total_inserts(self) -> int:
        return sum(self.inserts.values())

    def total_errors(self) -> int:
        return sum(self.errors.values())

    def avg_latency(self) -> float:
        if not self.latencies:
            return 0
        return sum(self.latencies) / len(self.latencies)

    def p99_latency(self) -> float:
        if not self.latencies:
            return 0
        sorted_lat = sorted(self.latencies)
        idx = int(len(sorted_lat) * 0.99)
        return sorted_lat[min(idx, len(sorted_lat) - 1)]

    def throughput(self) -> float:
        duration = (self.end_time or time.time()) - self.start_time
        if duration <= 0:
            return 0
        return self.total_inserts() / duration


# =============================================================================
# Database Helpers
# =============================================================================

def get_mysql_connection():
    """Get MySQL connection"""
    return mysql.connector.connect(**MYSQL_CONFIG)


def get_starrocks_connection():
    """Get StarRocks connection"""
    return mysql.connector.connect(**STARROCKS_CONFIG)


def get_table_counts(conn, tables: List[str]) -> Dict[str, int]:
    """Get row counts for tables"""
    counts = {}
    cursor = conn.cursor()
    for table in tables:
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {table}")
            counts[table] = cursor.fetchone()[0]
        except Exception as e:
            counts[table] = -1
    cursor.close()
    return counts


# =============================================================================
# Data Generators
# =============================================================================

def random_string(length: int = 8) -> str:
    return ''.join(random.choices(string.ascii_lowercase, k=length))


def random_email(marker: str) -> str:
    return f"bench_{marker}_{random_string(6)}@example.com"


def random_phone() -> str:
    return f"555-{random.randint(1000, 9999)}"


def random_sku(marker: str) -> str:
    return f"BENCH_{marker}_{random_string(8).upper()}"


def random_price(max_val: float = 1000.0) -> float:
    return round(random.uniform(1.0, max_val), 2)


def random_quantity(max_val: int = 100) -> int:
    return random.randint(1, max_val)


# =============================================================================
# Insert Functions
# =============================================================================

def insert_customer(cursor, marker: str) -> int:
    """Insert a customer and return ID"""
    tiers = ['BRONZE', 'SILVER', 'GOLD', 'PLATINUM']
    sql = """
        INSERT INTO customers
        (first_name, last_name, email, phone, registration_date, customer_tier, total_orders, total_spent)
        VALUES (%s, %s, %s, %s, CURDATE(), %s, %s, %s)
    """
    values = (
        f'Bench_{random_string(4)}',
        f'User_{marker}',
        random_email(marker),
        random_phone(),
        random.choice(tiers),
        random.randint(0, 50),
        random_price(5000)
    )
    cursor.execute(sql, values)
    return cursor.lastrowid


def insert_product(cursor, marker: str) -> int:
    """Insert a product and return ID"""
    categories = ['Electronics', 'Clothing', 'Home', 'Sports', 'Books', 'Toys', 'Food']
    sql = """
        INSERT INTO products
        (sku, product_name, category, price, stock_quantity, is_active)
        VALUES (%s, %s, %s, %s, %s, %s)
    """
    values = (
        random_sku(marker),
        f'Benchmark Product {random_string(6)}',
        random.choice(categories),
        random_price(500),
        random_quantity(1000),
        True
    )
    cursor.execute(sql, values)
    return cursor.lastrowid


def insert_order(cursor, marker: str, customer_id: int) -> int:
    """Insert an order and return ID"""
    statuses = ['PENDING', 'PROCESSING', 'SHIPPED', 'DELIVERED']
    sql = """
        INSERT INTO orders
        (customer_id, order_status, total_amount, shipping_address)
        VALUES (%s, %s, %s, %s)
    """
    values = (
        customer_id,
        random.choice(statuses),
        random_price(1000),
        f'bench_addr_{marker}_{random_string(8)}'
    )
    cursor.execute(sql, values)
    return cursor.lastrowid


def insert_order_item(cursor, marker: str, order_id: int, product_id: int) -> int:
    """Insert an order item and return ID"""
    qty = random_quantity(10)
    unit_price = random_price(100)
    sql = """
        INSERT INTO order_items
        (order_id, product_id, quantity, unit_price, total_price)
        VALUES (%s, %s, %s, %s, %s)
    """
    values = (
        order_id,
        product_id,
        qty,
        unit_price,
        round(qty * unit_price, 2)
    )
    cursor.execute(sql, values)
    return cursor.lastrowid


def insert_inventory_movement(cursor, marker: str, product_id: int) -> int:
    """Insert an inventory movement and return ID"""
    types = ['IN', 'OUT', 'ADJUSTMENT', 'RETURN']
    sql = """
        INSERT INTO inventory_movements
        (product_id, movement_type, quantity, reference_id, notes)
        VALUES (%s, %s, %s, %s, %s)
    """
    values = (
        product_id,
        random.choice(types),
        random_quantity(100),
        None,
        f'Benchmark movement {marker}'
    )
    cursor.execute(sql, values)
    return cursor.lastrowid


# =============================================================================
# Worker Functions
# =============================================================================

def worker_insert_batch(
    worker_id: int,
    marker: str,
    batch_size: int,
    stats: Stats,
    stop_event: threading.Event
) -> None:
    """Worker that inserts batches of records across all tables"""
    conn = get_mysql_connection()
    cursor = conn.cursor()

    # Get existing IDs for foreign keys
    cursor.execute("SELECT customer_id FROM customers LIMIT 100")
    existing_customers = [row[0] for row in cursor.fetchall()]
    cursor.execute("SELECT product_id FROM products LIMIT 100")
    existing_products = [row[0] for row in cursor.fetchall()]

    batch_num = 0
    while not stop_event.is_set():
        batch_num += 1
        batch_marker = f"{marker}_w{worker_id}_b{batch_num}"

        try:
            for _ in range(batch_size):
                if stop_event.is_set():
                    break

                start = time.time()

                # Insert customer
                cust_id = insert_customer(cursor, batch_marker)
                conn.commit()
                stats.record_insert('customers', (time.time() - start) * 1000)

                # Insert product
                start = time.time()
                prod_id = insert_product(cursor, batch_marker)
                conn.commit()
                stats.record_insert('products', (time.time() - start) * 1000)

                # Insert order (use existing customer for FK)
                start = time.time()
                use_cust_id = random.choice(existing_customers) if existing_customers else cust_id
                order_id = insert_order(cursor, batch_marker, use_cust_id)
                conn.commit()
                stats.record_insert('orders', (time.time() - start) * 1000)

                # Insert order item
                start = time.time()
                use_prod_id = random.choice(existing_products) if existing_products else prod_id
                insert_order_item(cursor, batch_marker, order_id, use_prod_id)
                conn.commit()
                stats.record_insert('order_items', (time.time() - start) * 1000)

                # Insert inventory movement
                start = time.time()
                insert_inventory_movement(cursor, batch_marker, use_prod_id)
                conn.commit()
                stats.record_insert('inventory_movements', (time.time() - start) * 1000)

                # Update existing IDs pool
                existing_customers.append(cust_id)
                existing_products.append(prod_id)
                if len(existing_customers) > 200:
                    existing_customers = existing_customers[-100:]
                if len(existing_products) > 200:
                    existing_products = existing_products[-100:]

        except Exception as e:
            stats.record_error('unknown')
            print(f"Worker {worker_id} error: {e}")

    cursor.close()
    conn.close()


def worker_single_table(
    worker_id: int,
    table: str,
    marker: str,
    stats: Stats,
    stop_event: threading.Event,
    rate_limit: float = 0
) -> None:
    """Worker that inserts into a single table"""
    conn = get_mysql_connection()
    cursor = conn.cursor()

    # Get existing IDs for foreign keys
    existing_customers = []
    existing_products = []
    existing_orders = []

    if table in ['orders', 'order_items']:
        cursor.execute("SELECT customer_id FROM customers LIMIT 100")
        existing_customers = [row[0] for row in cursor.fetchall()]
    if table in ['order_items', 'inventory_movements']:
        cursor.execute("SELECT product_id FROM products LIMIT 100")
        existing_products = [row[0] for row in cursor.fetchall()]
    if table == 'order_items':
        cursor.execute("SELECT order_id FROM orders LIMIT 100")
        existing_orders = [row[0] for row in cursor.fetchall()]

    count = 0
    while not stop_event.is_set():
        count += 1
        rec_marker = f"{marker}_w{worker_id}_{count}"

        try:
            start = time.time()

            if table == 'customers':
                insert_customer(cursor, rec_marker)
            elif table == 'products':
                insert_product(cursor, rec_marker)
            elif table == 'orders':
                cust_id = random.choice(existing_customers) if existing_customers else 1
                insert_order(cursor, rec_marker, cust_id)
            elif table == 'order_items':
                order_id = random.choice(existing_orders) if existing_orders else 1
                prod_id = random.choice(existing_products) if existing_products else 1
                insert_order_item(cursor, rec_marker, order_id, prod_id)
            elif table == 'inventory_movements':
                prod_id = random.choice(existing_products) if existing_products else 1
                insert_inventory_movement(cursor, rec_marker, prod_id)

            conn.commit()
            latency = (time.time() - start) * 1000
            stats.record_insert(table, latency)

            if rate_limit > 0:
                time.sleep(1.0 / rate_limit)

        except Exception as e:
            stats.record_error(table)
            conn.rollback()

    cursor.close()
    conn.close()


# =============================================================================
# Benchmark Modes
# =============================================================================

def run_parallel_benchmark(
    duration: int,
    workers: int,
    batch_size: int,
    stats: Stats,
    stop_event: threading.Event
) -> None:
    """Run parallel benchmark with multiple workers inserting all tables"""
    marker = f"para_{int(time.time())}"

    print(f"\n{'='*60}")
    print(f"PARALLEL BENCHMARK - {workers} workers, {batch_size} batch size")
    print(f"Duration: {duration}s | Tables: {', '.join(TABLES)}")
    print(f"{'='*60}\n")

    stats.start_time = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = []
        for i in range(workers):
            future = executor.submit(
                worker_insert_batch, i, marker, batch_size, stats, stop_event
            )
            futures.append(future)

        # Monitor progress
        try:
            end_time = time.time() + duration
            while time.time() < end_time and not stop_event.is_set():
                time.sleep(1)
                print_progress(stats)

        except KeyboardInterrupt:
            pass

        stop_event.set()
        concurrent.futures.wait(futures, timeout=5)

    stats.end_time = time.time()


def run_per_table_benchmark(
    duration: int,
    workers_per_table: int,
    rate_limit: float,
    stats: Stats,
    stop_event: threading.Event
) -> None:
    """Run benchmark with dedicated workers per table"""
    marker = f"tbl_{int(time.time())}"
    total_workers = workers_per_table * len(TABLES)

    print(f"\n{'='*60}")
    print(f"PER-TABLE BENCHMARK - {workers_per_table} workers/table")
    print(f"Duration: {duration}s | Rate limit: {rate_limit}/sec/worker")
    print(f"Total workers: {total_workers}")
    print(f"{'='*60}\n")

    stats.start_time = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=total_workers) as executor:
        futures = []
        worker_id = 0
        for table in TABLES:
            for _ in range(workers_per_table):
                future = executor.submit(
                    worker_single_table, worker_id, table, marker,
                    stats, stop_event, rate_limit
                )
                futures.append(future)
                worker_id += 1

        # Monitor progress
        try:
            end_time = time.time() + duration
            while time.time() < end_time and not stop_event.is_set():
                time.sleep(1)
                print_progress(stats)

        except KeyboardInterrupt:
            pass

        stop_event.set()
        concurrent.futures.wait(futures, timeout=5)

    stats.end_time = time.time()


def run_burst_benchmark(
    bursts: int,
    records_per_burst: int,
    pause_between: float,
    stats: Stats,
    stop_event: threading.Event
) -> None:
    """Run burst benchmark with pauses between bursts"""
    marker = f"burst_{int(time.time())}"

    print(f"\n{'='*60}")
    print(f"BURST BENCHMARK - {bursts} bursts, {records_per_burst} records each")
    print(f"Pause between bursts: {pause_between}s")
    print(f"{'='*60}\n")

    stats.start_time = time.time()
    conn = get_mysql_connection()
    cursor = conn.cursor()

    # Get existing IDs
    cursor.execute("SELECT customer_id FROM customers LIMIT 100")
    customers = [row[0] for row in cursor.fetchall()]
    cursor.execute("SELECT product_id FROM products LIMIT 100")
    products = [row[0] for row in cursor.fetchall()]

    try:
        for burst in range(bursts):
            if stop_event.is_set():
                break

            print(f"\n--- Burst {burst + 1}/{bursts} ---")
            burst_start = time.time()

            for i in range(records_per_burst):
                if stop_event.is_set():
                    break

                rec_marker = f"{marker}_b{burst}_{i}"
                start = time.time()

                # Insert all tables in one transaction
                cust_id = insert_customer(cursor, rec_marker)
                stats.record_insert('customers', (time.time() - start) * 1000)

                start = time.time()
                prod_id = insert_product(cursor, rec_marker)
                stats.record_insert('products', (time.time() - start) * 1000)

                start = time.time()
                use_cust = random.choice(customers) if customers else cust_id
                order_id = insert_order(cursor, rec_marker, use_cust)
                stats.record_insert('orders', (time.time() - start) * 1000)

                start = time.time()
                use_prod = random.choice(products) if products else prod_id
                insert_order_item(cursor, rec_marker, order_id, use_prod)
                stats.record_insert('order_items', (time.time() - start) * 1000)

                start = time.time()
                insert_inventory_movement(cursor, rec_marker, use_prod)
                stats.record_insert('inventory_movements', (time.time() - start) * 1000)

                conn.commit()
                customers.append(cust_id)
                products.append(prod_id)

            burst_duration = time.time() - burst_start
            print(f"Burst completed in {burst_duration:.2f}s")
            print_progress(stats)

            if burst < bursts - 1 and not stop_event.is_set():
                print(f"Pausing {pause_between}s...")
                time.sleep(pause_between)

    except KeyboardInterrupt:
        pass

    cursor.close()
    conn.close()
    stats.end_time = time.time()


def run_unlimited_benchmark(
    workers: int,
    rate_per_worker: float,
    stats: Stats,
    stop_event: threading.Event
) -> None:
    """Run unlimited benchmark until Ctrl+C"""
    marker = f"unlim_{int(time.time())}"

    print(f"\n{'='*60}")
    print(f"UNLIMITED BENCHMARK - {workers} workers")
    print(f"Rate limit: {rate_per_worker}/sec per worker")
    print(f"Press Ctrl+C to stop")
    print(f"{'='*60}\n")

    stats.start_time = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers * len(TABLES)) as executor:
        futures = []
        worker_id = 0
        for table in TABLES:
            for _ in range(workers):
                future = executor.submit(
                    worker_single_table, worker_id, table, marker,
                    stats, stop_event, rate_per_worker
                )
                futures.append(future)
                worker_id += 1

        # Monitor progress until interrupted
        try:
            while not stop_event.is_set():
                time.sleep(2)
                print_progress(stats)

        except KeyboardInterrupt:
            pass

        stop_event.set()
        concurrent.futures.wait(futures, timeout=5)

    stats.end_time = time.time()


# =============================================================================
# CDC Verification
# =============================================================================

def verify_cdc_sync(timeout: int = 60) -> Dict:
    """Verify CDC sync between MySQL and StarRocks"""
    print(f"\n{'='*60}")
    print("VERIFYING CDC SYNC")
    print(f"{'='*60}\n")

    try:
        mysql_conn = get_mysql_connection()
        sr_conn = get_starrocks_connection()

        mysql_counts = get_table_counts(mysql_conn, TABLES)
        print("MySQL counts:", mysql_counts)

        # Wait for sync
        start = time.time()
        synced = False
        while time.time() - start < timeout:
            sr_counts = get_table_counts(sr_conn, TABLES)
            print(f"StarRocks counts: {sr_counts}", end='\r')

            if all(sr_counts.get(t, 0) >= mysql_counts.get(t, 0) for t in TABLES):
                synced = True
                break

            time.sleep(2)

        print()
        sr_counts = get_table_counts(sr_conn, TABLES)

        result = {
            'synced': synced,
            'mysql': mysql_counts,
            'starrocks': sr_counts,
            'lag': {t: mysql_counts.get(t, 0) - sr_counts.get(t, 0) for t in TABLES},
            'sync_time': time.time() - start if synced else timeout
        }

        mysql_conn.close()
        sr_conn.close()

        return result

    except Exception as e:
        return {'error': str(e)}


# =============================================================================
# Output Functions
# =============================================================================

def print_progress(stats: Stats) -> None:
    """Print current progress"""
    elapsed = time.time() - stats.start_time
    throughput = stats.total_inserts() / elapsed if elapsed > 0 else 0

    print(f"\r[{elapsed:.1f}s] Total: {stats.total_inserts():,} | "
          f"Rate: {throughput:.1f}/s | "
          f"Errors: {stats.total_errors()} | "
          f"Avg latency: {stats.avg_latency():.1f}ms", end='')


def print_summary(stats: Stats, cdc_result: Optional[Dict] = None) -> None:
    """Print final summary"""
    duration = stats.end_time - stats.start_time

    print(f"\n\n{'='*60}")
    print("BENCHMARK SUMMARY")
    print(f"{'='*60}")
    print(f"Duration:        {duration:.2f}s")
    print(f"Total inserts:   {stats.total_inserts():,}")
    print(f"Total errors:    {stats.total_errors()}")
    print(f"Throughput:      {stats.throughput():.2f} records/sec")
    print(f"Avg latency:     {stats.avg_latency():.2f}ms")
    print(f"P99 latency:     {stats.p99_latency():.2f}ms")

    print(f"\nPer-table inserts:")
    for table in TABLES:
        print(f"  {table:25} {stats.inserts[table]:,}")

    if cdc_result:
        print(f"\nCDC Sync Status:")
        if 'error' in cdc_result:
            print(f"  Error: {cdc_result['error']}")
        else:
            print(f"  Synced: {cdc_result['synced']}")
            print(f"  Sync time: {cdc_result.get('sync_time', 'N/A'):.2f}s")
            if cdc_result.get('lag'):
                print(f"  Lag by table:")
                for table, lag in cdc_result['lag'].items():
                    print(f"    {table:25} {lag:,}")

    print(f"{'='*60}\n")


def cleanup_benchmark_data() -> None:
    """Clean up benchmark test data"""
    print("Cleaning up benchmark data...")

    conn = get_mysql_connection()
    cursor = conn.cursor()

    # Delete in order respecting foreign keys
    cursor.execute("DELETE FROM order_items WHERE order_id IN (SELECT order_id FROM orders WHERE shipping_address LIKE 'bench_addr_%')")
    cursor.execute("DELETE FROM orders WHERE shipping_address LIKE 'bench_addr_%'")
    cursor.execute("DELETE FROM inventory_movements WHERE notes LIKE 'Benchmark movement %'")
    cursor.execute("DELETE FROM products WHERE sku LIKE 'BENCH_%'")
    cursor.execute("DELETE FROM customers WHERE email LIKE 'bench_%'")

    conn.commit()
    cursor.close()
    conn.close()

    print("Cleanup complete!")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='CDC Benchmark - Parallel Load Testing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s parallel -d 60 -w 4           # 4 workers for 60 seconds
  %(prog)s per-table -d 30 -w 2 -r 10    # 2 workers/table, 10 records/sec
  %(prog)s burst -b 5 -n 100 -p 10       # 5 bursts of 100 records, 10s pause
  %(prog)s unlimited -w 2 -r 5           # Unlimited until Ctrl+C
  %(prog)s verify                         # Check CDC sync status
  %(prog)s cleanup                        # Remove benchmark data
        """
    )

    subparsers = parser.add_subparsers(dest='mode', help='Benchmark mode')

    # Parallel mode
    p_parallel = subparsers.add_parser('parallel', help='Parallel workers inserting all tables')
    p_parallel.add_argument('-d', '--duration', type=int, default=60, help='Duration in seconds (default: 60)')
    p_parallel.add_argument('-w', '--workers', type=int, default=4, help='Number of workers (default: 4)')
    p_parallel.add_argument('-b', '--batch', type=int, default=10, help='Batch size per worker (default: 10)')

    # Per-table mode
    p_table = subparsers.add_parser('per-table', help='Dedicated workers per table')
    p_table.add_argument('-d', '--duration', type=int, default=60, help='Duration in seconds (default: 60)')
    p_table.add_argument('-w', '--workers', type=int, default=2, help='Workers per table (default: 2)')
    p_table.add_argument('-r', '--rate', type=float, default=0, help='Rate limit per worker (default: unlimited)')

    # Burst mode
    p_burst = subparsers.add_parser('burst', help='Burst inserts with pauses')
    p_burst.add_argument('-b', '--bursts', type=int, default=5, help='Number of bursts (default: 5)')
    p_burst.add_argument('-n', '--records', type=int, default=100, help='Records per burst (default: 100)')
    p_burst.add_argument('-p', '--pause', type=float, default=5, help='Pause between bursts in seconds (default: 5)')

    # Unlimited mode
    p_unlim = subparsers.add_parser('unlimited', help='Unlimited loading until Ctrl+C')
    p_unlim.add_argument('-w', '--workers', type=int, default=2, help='Workers per table (default: 2)')
    p_unlim.add_argument('-r', '--rate', type=float, default=5, help='Rate per worker (default: 5/sec)')

    # Verify mode
    subparsers.add_parser('verify', help='Verify CDC sync status')

    # Cleanup mode
    subparsers.add_parser('cleanup', help='Remove benchmark test data')

    # Counts mode
    subparsers.add_parser('counts', help='Show current table counts')

    args = parser.parse_args()

    if not args.mode:
        parser.print_help()
        return

    # Setup signal handler
    stop_event = threading.Event()

    def signal_handler(sig, frame):
        print("\n\nStopping benchmark...")
        stop_event.set()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    stats = Stats()

    try:
        if args.mode == 'parallel':
            run_parallel_benchmark(args.duration, args.workers, args.batch, stats, stop_event)
            cdc_result = verify_cdc_sync()
            print_summary(stats, cdc_result)

        elif args.mode == 'per-table':
            run_per_table_benchmark(args.duration, args.workers, args.rate, stats, stop_event)
            cdc_result = verify_cdc_sync()
            print_summary(stats, cdc_result)

        elif args.mode == 'burst':
            run_burst_benchmark(args.bursts, args.records, args.pause, stats, stop_event)
            cdc_result = verify_cdc_sync()
            print_summary(stats, cdc_result)

        elif args.mode == 'unlimited':
            run_unlimited_benchmark(args.workers, args.rate, stats, stop_event)
            cdc_result = verify_cdc_sync()
            print_summary(stats, cdc_result)

        elif args.mode == 'verify':
            result = verify_cdc_sync()
            print(json.dumps(result, indent=2))

        elif args.mode == 'cleanup':
            cleanup_benchmark_data()

        elif args.mode == 'counts':
            print("\nTable Counts:")
            print("-" * 50)
            try:
                mysql_conn = get_mysql_connection()
                mysql_counts = get_table_counts(mysql_conn, TABLES)
                mysql_conn.close()
                print("MySQL:")
                for t, c in mysql_counts.items():
                    print(f"  {t:25} {c:,}")
            except Exception as e:
                print(f"MySQL error: {e}")

            try:
                sr_conn = get_starrocks_connection()
                sr_counts = get_table_counts(sr_conn, TABLES)
                sr_conn.close()
                print("\nStarRocks:")
                for t, c in sr_counts.items():
                    print(f"  {t:25} {c:,}")
            except Exception as e:
                print(f"StarRocks error: {e}")

    except Exception as e:
        print(f"Error: {e}")
        raise


if __name__ == '__main__':
    main()
