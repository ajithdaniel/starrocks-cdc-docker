#!/usr/bin/env python3
"""
CDC Latency Monitor - Real-time monitoring of MySQL to StarRocks CDC pipeline

Features:
- Real-time latency measurement using marker records
- Table sync lag monitoring
- Throughput tracking
- Visual dashboard with live updates
- Alert thresholds for latency spikes
- Historical latency statistics
"""

import argparse
import curses
import json
import mysql.connector
import os
import signal
import sys
import threading
import time
from collections import deque
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

# Latency thresholds (ms)
LATENCY_OK = 2000        # Green: < 2s
LATENCY_WARN = 5000      # Yellow: 2-5s
LATENCY_CRITICAL = 10000 # Red: > 10s

# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class LatencyMeasurement:
    """Single latency measurement"""
    timestamp: float
    table: str
    latency_ms: float
    success: bool

@dataclass
class TableStats:
    """Statistics for a single table"""
    mysql_count: int = 0
    starrocks_count: int = 0
    lag: int = 0
    last_latency_ms: float = 0
    latency_history: deque = field(default_factory=lambda: deque(maxlen=100))

    def avg_latency(self) -> float:
        if not self.latency_history:
            return 0
        return sum(self.latency_history) / len(self.latency_history)

    def min_latency(self) -> float:
        if not self.latency_history:
            return 0
        return min(self.latency_history)

    def max_latency(self) -> float:
        if not self.latency_history:
            return 0
        return max(self.latency_history)

    def p95_latency(self) -> float:
        if not self.latency_history:
            return 0
        sorted_lat = sorted(self.latency_history)
        idx = int(len(sorted_lat) * 0.95)
        return sorted_lat[min(idx, len(sorted_lat) - 1)]

@dataclass
class MonitorState:
    """Global monitoring state"""
    running: bool = True
    tables: Dict[str, TableStats] = field(default_factory=lambda: {t: TableStats() for t in TABLES})
    total_probes: int = 0
    successful_probes: int = 0
    failed_probes: int = 0
    start_time: float = field(default_factory=time.time)
    last_update: float = 0
    error_message: str = ""
    lock: threading.Lock = field(default_factory=threading.Lock)

# =============================================================================
# Database Connections
# =============================================================================

def get_mysql_connection():
    """Get MySQL connection with retry"""
    for attempt in range(3):
        try:
            return mysql.connector.connect(**MYSQL_CONFIG)
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(1)

def get_starrocks_connection():
    """Get StarRocks connection with retry"""
    for attempt in range(3):
        try:
            return mysql.connector.connect(**STARROCKS_CONFIG)
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(1)

# =============================================================================
# Latency Probing
# =============================================================================

def probe_latency(state: MonitorState, table: str = 'orders') -> Optional[float]:
    """
    Probe CDC latency by inserting a marker record and measuring sync time.
    Uses orders table by default as it's the most commonly used.
    """
    marker = f"probe_{int(time.time() * 1000)}_{os.getpid()}"

    try:
        # Insert marker into MySQL
        mysql_conn = get_mysql_connection()
        mysql_cursor = mysql_conn.cursor()

        insert_time = time.time()

        if table == 'orders':
            mysql_cursor.execute(
                "INSERT INTO orders (customer_id, order_status, total_amount, shipping_address) "
                "VALUES (1, 'PROBE', 0.01, %s)",
                (marker,)
            )
        elif table == 'customers':
            mysql_cursor.execute(
                "INSERT INTO customers (first_name, last_name, email, phone, registration_date, customer_tier, total_orders, total_spent) "
                "VALUES ('Probe', %s, %s, '555-0000', CURDATE(), 'BRONZE', 0, 0)",
                (marker, f"probe_{marker}@monitor.local")
            )
        elif table == 'products':
            mysql_cursor.execute(
                "INSERT INTO products (sku, product_name, category, price, stock_quantity, is_active) "
                "VALUES (%s, 'Probe Product', 'PROBE', 0.01, 1, true)",
                (f"PROBE_{marker}",)
            )
        elif table == 'inventory_movements':
            mysql_cursor.execute(
                "INSERT INTO inventory_movements (product_id, movement_type, quantity, notes) "
                "VALUES (1, 'PROBE', 1, %s)",
                (marker,)
            )

        mysql_conn.commit()
        mysql_cursor.close()
        mysql_conn.close()

        # Poll StarRocks for the marker
        sr_conn = get_starrocks_connection()
        sr_cursor = sr_conn.cursor()

        timeout = 30  # 30 second timeout
        poll_interval = 0.1  # 100ms polling

        while time.time() - insert_time < timeout:
            try:
                if table == 'orders':
                    sr_cursor.execute(
                        "SELECT COUNT(*) FROM orders WHERE shipping_address = %s",
                        (marker,)
                    )
                elif table == 'customers':
                    sr_cursor.execute(
                        "SELECT COUNT(*) FROM customers WHERE email = %s",
                        (f"probe_{marker}@monitor.local",)
                    )
                elif table == 'products':
                    sr_cursor.execute(
                        "SELECT COUNT(*) FROM products WHERE sku = %s",
                        (f"PROBE_{marker}",)
                    )
                elif table == 'inventory_movements':
                    sr_cursor.execute(
                        "SELECT COUNT(*) FROM inventory_movements WHERE notes = %s",
                        (marker,)
                    )

                count = sr_cursor.fetchone()[0]
                if count > 0:
                    latency_ms = (time.time() - insert_time) * 1000
                    sr_cursor.close()
                    sr_conn.close()

                    # Clean up probe record
                    cleanup_probe(table, marker)

                    return latency_ms

            except Exception:
                pass

            time.sleep(poll_interval)

        sr_cursor.close()
        sr_conn.close()

        # Timeout - clean up and return None
        cleanup_probe(table, marker)
        return None

    except Exception as e:
        with state.lock:
            state.error_message = str(e)
        return None

def cleanup_probe(table: str, marker: str):
    """Clean up probe record from MySQL (will cascade to StarRocks via CDC)"""
    try:
        conn = get_mysql_connection()
        cursor = conn.cursor()

        if table == 'orders':
            cursor.execute("DELETE FROM orders WHERE shipping_address = %s", (marker,))
        elif table == 'customers':
            cursor.execute("DELETE FROM customers WHERE email = %s", (f"probe_{marker}@monitor.local",))
        elif table == 'products':
            cursor.execute("DELETE FROM products WHERE sku = %s", (f"PROBE_{marker}",))
        elif table == 'inventory_movements':
            cursor.execute("DELETE FROM inventory_movements WHERE notes = %s", (marker,))

        conn.commit()
        cursor.close()
        conn.close()
    except Exception:
        pass

def get_table_counts(state: MonitorState):
    """Update table counts from both databases"""
    try:
        mysql_conn = get_mysql_connection()
        mysql_cursor = mysql_conn.cursor()

        sr_conn = get_starrocks_connection()
        sr_cursor = sr_conn.cursor()

        with state.lock:
            for table in TABLES:
                try:
                    mysql_cursor.execute(f"SELECT COUNT(*) FROM {table}")
                    state.tables[table].mysql_count = mysql_cursor.fetchone()[0]

                    sr_cursor.execute(f"SELECT COUNT(*) FROM {table}")
                    state.tables[table].starrocks_count = sr_cursor.fetchone()[0]

                    state.tables[table].lag = (
                        state.tables[table].mysql_count -
                        state.tables[table].starrocks_count
                    )
                except Exception:
                    pass

        mysql_cursor.close()
        mysql_conn.close()
        sr_cursor.close()
        sr_conn.close()

    except Exception as e:
        with state.lock:
            state.error_message = str(e)

# =============================================================================
# Monitoring Threads
# =============================================================================

def latency_probe_thread(state: MonitorState, interval: float, tables: List[str]):
    """Thread that continuously probes latency"""
    table_idx = 0

    while state.running:
        table = tables[table_idx % len(tables)]
        table_idx += 1

        latency = probe_latency(state, table)

        with state.lock:
            state.total_probes += 1
            if latency is not None:
                state.successful_probes += 1
                state.tables[table].last_latency_ms = latency
                state.tables[table].latency_history.append(latency)
            else:
                state.failed_probes += 1
                state.tables[table].last_latency_ms = -1

        time.sleep(interval)

def counts_update_thread(state: MonitorState, interval: float):
    """Thread that updates table counts"""
    while state.running:
        get_table_counts(state)
        with state.lock:
            state.last_update = time.time()
        time.sleep(interval)

# =============================================================================
# Display Functions
# =============================================================================

def get_latency_color(latency_ms: float) -> str:
    """Get ANSI color code for latency value"""
    if latency_ms < 0:
        return '\033[91m'  # Red (failed)
    elif latency_ms < LATENCY_OK:
        return '\033[92m'  # Green
    elif latency_ms < LATENCY_WARN:
        return '\033[93m'  # Yellow
    else:
        return '\033[91m'  # Red

def format_latency(latency_ms: float) -> str:
    """Format latency for display"""
    if latency_ms < 0:
        return "TIMEOUT"
    elif latency_ms < 1000:
        return f"{latency_ms:.0f}ms"
    else:
        return f"{latency_ms/1000:.2f}s"

def display_dashboard(state: MonitorState):
    """Display monitoring dashboard (non-curses version)"""
    while state.running:
        os.system('clear' if os.name != 'nt' else 'cls')

        uptime = time.time() - state.start_time
        success_rate = (state.successful_probes / state.total_probes * 100) if state.total_probes > 0 else 0

        print("=" * 80)
        print("  CDC LATENCY MONITOR - MySQL to StarRocks Pipeline")
        print("=" * 80)
        print(f"  Uptime: {uptime:.0f}s | Probes: {state.total_probes} | "
              f"Success: {success_rate:.1f}% | Last Update: {datetime.now().strftime('%H:%M:%S')}")
        print("=" * 80)
        print()

        # Table header
        print(f"  {'Table':<25} {'MySQL':>10} {'StarRocks':>12} {'Lag':>8} "
              f"{'Last Latency':>14} {'Avg':>10} {'P95':>10}")
        print("-" * 80)

        with state.lock:
            for table in TABLES:
                stats = state.tables[table]
                color = get_latency_color(stats.last_latency_ms)
                reset = '\033[0m'

                lag_str = f"{stats.lag:+d}" if stats.lag != 0 else "0"
                lag_color = '\033[93m' if stats.lag > 0 else '\033[92m'

                print(f"  {table:<25} {stats.mysql_count:>10,} {stats.starrocks_count:>12,} "
                      f"{lag_color}{lag_str:>8}{reset} "
                      f"{color}{format_latency(stats.last_latency_ms):>14}{reset} "
                      f"{format_latency(stats.avg_latency()):>10} "
                      f"{format_latency(stats.p95_latency()):>10}")

        print()
        print("-" * 80)

        # Overall stats
        all_latencies = []
        with state.lock:
            for table in TABLES:
                all_latencies.extend(list(state.tables[table].latency_history))

        if all_latencies:
            overall_avg = sum(all_latencies) / len(all_latencies)
            overall_min = min(all_latencies)
            overall_max = max(all_latencies)
            sorted_lat = sorted(all_latencies)
            overall_p95 = sorted_lat[int(len(sorted_lat) * 0.95)] if sorted_lat else 0

            print(f"  Overall: Avg={format_latency(overall_avg)} | "
                  f"Min={format_latency(overall_min)} | "
                  f"Max={format_latency(overall_max)} | "
                  f"P95={format_latency(overall_p95)}")

        print()

        # Error message if any
        with state.lock:
            if state.error_message:
                print(f"\033[91m  Error: {state.error_message}\033[0m")
                state.error_message = ""

        print()
        print("  Press Ctrl+C to stop")
        print("=" * 80)

        time.sleep(1)

def display_simple(state: MonitorState):
    """Simple line-by-line output for logging"""
    last_probe_count = 0

    while state.running:
        with state.lock:
            if state.total_probes > last_probe_count:
                last_probe_count = state.total_probes

                # Find the table that was just probed
                for table in TABLES:
                    stats = state.tables[table]
                    if stats.last_latency_ms != 0:
                        latency_str = format_latency(stats.last_latency_ms)
                        lag = stats.lag
                        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                        status = "OK" if stats.last_latency_ms > 0 and stats.last_latency_ms < LATENCY_WARN else "WARN"
                        if stats.last_latency_ms < 0 or stats.last_latency_ms >= LATENCY_CRITICAL:
                            status = "CRIT"

                        print(f"[{timestamp}] [{status:4}] {table:<25} "
                              f"latency={latency_str:>10} lag={lag:>5} "
                              f"mysql={stats.mysql_count:>8} sr={stats.starrocks_count:>8}")

        time.sleep(0.5)

def display_json(state: MonitorState):
    """JSON output for integration with other tools"""
    last_probe_count = 0

    while state.running:
        with state.lock:
            if state.total_probes > last_probe_count:
                last_probe_count = state.total_probes

                data = {
                    'timestamp': datetime.now().isoformat(),
                    'uptime_seconds': time.time() - state.start_time,
                    'total_probes': state.total_probes,
                    'successful_probes': state.successful_probes,
                    'failed_probes': state.failed_probes,
                    'tables': {}
                }

                for table in TABLES:
                    stats = state.tables[table]
                    data['tables'][table] = {
                        'mysql_count': stats.mysql_count,
                        'starrocks_count': stats.starrocks_count,
                        'lag': stats.lag,
                        'last_latency_ms': stats.last_latency_ms,
                        'avg_latency_ms': stats.avg_latency(),
                        'p95_latency_ms': stats.p95_latency(),
                    }

                print(json.dumps(data))
                sys.stdout.flush()

        time.sleep(0.5)

# =============================================================================
# One-time Commands
# =============================================================================

def check_once(tables: List[str]) -> Dict:
    """Run a single latency check and return results"""
    results = {
        'timestamp': datetime.now().isoformat(),
        'tables': {}
    }

    state = MonitorState()
    get_table_counts(state)

    for table in tables:
        print(f"Probing {table}...", end=' ', flush=True)
        latency = probe_latency(state, table)

        stats = state.tables[table]
        results['tables'][table] = {
            'latency_ms': latency if latency else -1,
            'mysql_count': stats.mysql_count,
            'starrocks_count': stats.starrocks_count,
            'lag': stats.lag,
            'status': 'OK' if latency and latency < LATENCY_WARN else 'WARN' if latency else 'FAIL'
        }

        if latency:
            print(f"{format_latency(latency)}")
        else:
            print("TIMEOUT")

    return results

def show_status():
    """Show current sync status without probing"""
    print("\n" + "=" * 70)
    print("  CDC SYNC STATUS")
    print("=" * 70)

    try:
        mysql_conn = get_mysql_connection()
        mysql_cursor = mysql_conn.cursor()

        sr_conn = get_starrocks_connection()
        sr_cursor = sr_conn.cursor()

        print(f"\n  {'Table':<25} {'MySQL':>12} {'StarRocks':>12} {'Lag':>10} {'Status':>10}")
        print("-" * 70)

        total_lag = 0
        for table in TABLES:
            mysql_cursor.execute(f"SELECT COUNT(*) FROM {table}")
            mysql_count = mysql_cursor.fetchone()[0]

            sr_cursor.execute(f"SELECT COUNT(*) FROM {table}")
            sr_count = sr_cursor.fetchone()[0]

            lag = mysql_count - sr_count
            total_lag += abs(lag)

            status = "\033[92mSYNCED\033[0m" if lag == 0 else "\033[93mLAGGING\033[0m"
            lag_str = f"{lag:+d}" if lag != 0 else "0"

            print(f"  {table:<25} {mysql_count:>12,} {sr_count:>12,} {lag_str:>10} {status:>10}")

        print("-" * 70)
        overall_status = "\033[92mALL SYNCED\033[0m" if total_lag == 0 else f"\033[93mTOTAL LAG: {total_lag}\033[0m"
        print(f"  Overall: {overall_status}")
        print("=" * 70 + "\n")

        mysql_cursor.close()
        mysql_conn.close()
        sr_cursor.close()
        sr_conn.close()

    except Exception as e:
        print(f"\033[91mError: {e}\033[0m")

# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='CDC Latency Monitor - Real-time monitoring of MySQL to StarRocks CDC',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Modes:
  dashboard    Interactive dashboard with live updates (default)
  simple       Simple line-by-line output for logging
  json         JSON output for integration
  check        Single latency check and exit
  status       Show current sync status without probing

Examples:
  %(prog)s                           # Start dashboard
  %(prog)s dashboard -i 5            # Dashboard, probe every 5 seconds
  %(prog)s simple -t orders          # Simple output, orders table only
  %(prog)s json -t orders,customers  # JSON output for specific tables
  %(prog)s check                     # One-time check all tables
  %(prog)s status                    # Show current sync status
        """
    )

    parser.add_argument('mode', nargs='?', default='dashboard',
                        choices=['dashboard', 'simple', 'json', 'check', 'status'],
                        help='Output mode (default: dashboard)')
    parser.add_argument('-i', '--interval', type=float, default=2.0,
                        help='Probe interval in seconds (default: 2.0)')
    parser.add_argument('-t', '--tables', type=str, default=','.join(TABLES),
                        help=f'Comma-separated tables to monitor (default: all)')
    parser.add_argument('--latency-ok', type=int, default=LATENCY_OK,
                        help=f'Latency threshold for OK status in ms (default: {LATENCY_OK})')
    parser.add_argument('--latency-warn', type=int, default=LATENCY_WARN,
                        help=f'Latency threshold for WARN status in ms (default: {LATENCY_WARN})')

    args = parser.parse_args()

    # Parse tables
    tables = [t.strip() for t in args.tables.split(',') if t.strip() in TABLES]
    if not tables:
        tables = TABLES

    # Handle one-time commands
    if args.mode == 'check':
        results = check_once(tables)
        print("\nResults:")
        print(json.dumps(results, indent=2))
        return

    if args.mode == 'status':
        show_status()
        return

    # Create state and start monitoring
    state = MonitorState()

    def signal_handler(sig, frame):
        print("\n\nStopping monitor...")
        state.running = False

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Start background threads
    probe_thread = threading.Thread(
        target=latency_probe_thread,
        args=(state, args.interval, tables),
        daemon=True
    )
    probe_thread.start()

    counts_thread = threading.Thread(
        target=counts_update_thread,
        args=(state, 5.0),  # Update counts every 5 seconds
        daemon=True
    )
    counts_thread.start()

    # Start display
    try:
        if args.mode == 'dashboard':
            display_dashboard(state)
        elif args.mode == 'simple':
            display_simple(state)
        elif args.mode == 'json':
            display_json(state)
    except KeyboardInterrupt:
        pass

    state.running = False
    probe_thread.join(timeout=2)
    counts_thread.join(timeout=2)

    print("\nMonitor stopped.")

if __name__ == '__main__':
    main()
