# Contributing to MySQL to StarRocks Shared-Data CDC

Thank you for your interest in contributing to this project!

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/starrocks-cdc-docker.git
   cd starrocks-cdc-docker
   ```
3. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites

- Docker 20.10+
- Docker Compose 2.0+
- Python 3.8+ (for testing tools)

### Running Locally

```bash
# Start all services
docker-compose up -d

# Run tests
./scripts/test-cdc-latency-docker.sh all

# Check CDC is working
python scripts/cdc-monitor.py --mode status
```

## Project Structure

```
starrocks-cdc-docker/
├── docker-compose.yml      # Service orchestration
├── config/                 # Configuration files
│   ├── fe.conf            # StarRocks Frontend config
│   └── cn.conf            # StarRocks Compute Node config
├── scripts/               # Testing and utility scripts
│   ├── mysql-init.sql     # MySQL schema
│   ├── starrocks-init.sql # StarRocks schema
│   ├── test-cdc-latency-docker.sh  # Bash tests
│   ├── cdc-benchmark.py   # Python benchmark
│   └── cdc-monitor.py     # Python monitor
└── flink-cdc/             # Flink CDC configuration
    ├── setup-cdc.sh       # CDC initialization
    ├── cdc-orders.sql     # Single table CDC
    ├── cdc-all-tables-full.sql  # All tables CDC
    └── lib/               # Connector JARs
```

## Making Changes

### Code Style

- **Shell scripts**: Follow Google Shell Style Guide
- **Python**: Follow PEP 8, use type hints
- **SQL**: Use uppercase keywords, lowercase identifiers
- **YAML**: 2-space indentation

### Testing

Before submitting a PR, ensure:

1. All services start correctly:
   ```bash
   docker-compose up -d
   docker-compose ps  # All should be healthy
   ```

2. CDC is working:
   ```bash
   ./scripts/test-cdc-latency-docker.sh all
   ```

3. Python scripts run without errors:
   ```bash
   python scripts/cdc-benchmark.py --help
   python scripts/cdc-monitor.py --mode status
   ```

## Submitting Changes

1. Commit your changes:
   ```bash
   git add .
   git commit -m "feat: add new feature description"
   ```

2. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```

3. Create a Pull Request with:
   - Clear description of changes
   - Test results
   - Screenshots (if UI changes)

## Commit Message Format

Use conventional commits:

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Adding tests
- `chore:` - Maintenance tasks

Examples:
```
feat: add support for PostgreSQL source
fix: resolve CDC sync timeout issue
docs: update deployment guide for Kubernetes
```

## Reporting Issues

When reporting issues, include:

1. Environment details (OS, Docker version)
2. Steps to reproduce
3. Expected vs actual behavior
4. Relevant logs:
   ```bash
   docker-compose logs > logs.txt
   ```

## Feature Requests

For new features:

1. Check existing issues first
2. Describe the use case
3. Propose implementation approach (optional)

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
