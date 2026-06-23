# BusOps Data Platform

BusOps Data Platform is a lightweight analytics pipeline for bus operations data. It extracts operational records from a source PostgreSQL database, loads them into ClickHouse raw tables, and builds ClickHouse mart views for passenger, revenue, trip, route, and operations reporting.

The current project is an MVP: the core pipeline is script-driven, ClickHouse and Metabase are Dockerized, and Airflow/dbt folders are present for orchestration and modelling work as the platform grows.

## What This Project Does

- Pulls bus operations data from production PostgreSQL.
- Loads selected tables into ClickHouse `raw` tables.
- Recreates analytics views in the ClickHouse `marts` database.
- Runs validation checks after each pipeline run.
- Provides Metabase as the BI layer for dashboards and exploration.

## Architecture

```text
PostgreSQL source
      |
      | Python extraction scripts
      v
ClickHouse raw tables
      |
      | sql/marts/create_marts.sql
      v
ClickHouse mart views
      |
      v
Metabase dashboards
```

## Repository Layout

```text
.
├── airflow/                  # Local Airflow Docker setup; DAGs/plugins are placeholders
├── backups/                  # Local backup area, ignored by git
├── dbt/                      # Reserved for future dbt models
├── logs/                     # Pipeline logs, ignored by git
├── pipelines/                # Python extractors and the MVP runner
├── platform/                 # Docker Compose for ClickHouse and Metabase
└── sql/
    ├── audit/                # Reserved for future audit SQL
    ├── marts/                # ClickHouse mart view definitions
    └── raw/                  # Reserved for raw table DDL
```

## Main Components

### Platform Services

`platform/docker-compose.yml` starts:

- `busops-clickhouse`: ClickHouse analytics database, exposed on `127.0.0.1:8123`.
- `busops-metabase-db`: PostgreSQL database used by Metabase.
- `busops-metabase`: Metabase UI, exposed on `http://localhost:3001`.

The compose file uses an external Docker network named `busops-net`.

### Extraction Scripts

The scripts in `pipelines/` connect to PostgreSQL and ClickHouse using values from `/opt/busops-data/.env`.

| Script | Source table | ClickHouse table |
| --- | --- | --- |
| `extract_boarding_records.py` | `boarding_records` | `raw.boarding_records` |
| `extract_payment_transactions.py` | `payment_transactions` | `raw.payment_transactions` |
| `extract_trips.py` | `trips` | `raw.trips` |
| `extract_routes.py` | `routes` | `raw.routes` |
| `extract_buses.py` | `buses` | `raw.buses` |

The stable MVP runner currently excludes `extract_buses.py` because `raw.buses` was previously returning zero rows and bus marts are not yet part of the stable reporting layer.

### Mart Views

`sql/marts/create_marts.sql` creates the ClickHouse `marts` views, including:

- `marts.trip_passenger_summary`
- `marts.payment_status_summary`
- `marts.daily_revenue`
- `marts.revenue_by_type`
- `marts.revenue_by_franchise`
- `marts.route_context`
- `marts.trip_context`
- `marts.trip_revenue_summary`
- `marts.trip_passenger_revenue_summary`
- `marts.trip_operations_summary`
- `marts.daily_operations_summary`
- `marts.trip_operations_route_enriched`
- `marts.route_performance_summary`

## Prerequisites

- Docker and Docker Compose
- Python 3.12 or compatible Python 3
- Access to the source PostgreSQL database
- Existing ClickHouse `raw` tables and `marts` database
- A `.env` file at the project root

Python package requirements are not yet captured in a `requirements.txt`. The current scripts require:

```bash
pip install psycopg2-binary clickhouse-connect python-dotenv
```

## Environment Variables

Create `/opt/busops-data/.env` with the values needed by Docker Compose and the extraction scripts:

```dotenv
SOURCE_DB_HOST=
SOURCE_DB_PORT=5432
SOURCE_DB_NAME=
SOURCE_DB_USER=
SOURCE_DB_PASSWORD=

CLICKHOUSE_USER=
CLICKHOUSE_PASSWORD=

METABASE_DB_USER=
METABASE_DB_PASSWORD=
METABASE_DB_NAME=
```

The `.env` file is intentionally ignored by git.

## First-Time Setup

From the project root:

```bash
cd /opt/busops-data
```

Create the shared Docker network:

```bash
docker network create busops-net
```

Create and activate the Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install psycopg2-binary clickhouse-connect python-dotenv
```

Start ClickHouse and Metabase:

```bash
cd /opt/busops-data/platform
docker compose --env-file ../.env up -d
```

Metabase will be available at:

```text
http://localhost:3001
```

## Check Connections

Use the connection test before running the full pipeline:

```bash
cd /opt/busops-data
source .venv/bin/activate
python pipelines/test_connections.py
```

This checks:

- PostgreSQL access by counting `boarding_records`.
- ClickHouse access by printing the ClickHouse version.

## Run the MVP Pipeline

```bash
cd /opt/busops-data
bash pipelines/run_mvp_pipeline.sh
```

The runner performs these steps:

1. Loads environment variables from `.env`.
2. Verifies that `busops-clickhouse` is running.
3. Activates `.venv`.
4. Extracts boarding records, payment transactions, trips, and routes.
5. Recreates ClickHouse mart views.
6. Runs validation queries for raw counts, operations summaries, revenue, and payment status.

Pipeline output is printed to the terminal. The default log path used by the project is:

```text
/opt/busops-data/logs/mvp_pipeline.log
```

## Run Mart SQL Manually

If you only need to recreate the mart views:

```bash
docker exec -i busops-clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" \
  --password "$CLICKHOUSE_PASSWORD" \
  < /opt/busops-data/sql/marts/create_marts.sql
```

If the variables are only defined in `.env`, load them first:

```bash
set -a
source /opt/busops-data/.env
set +a
```

## Validation Queries

After a successful run, useful checks include:

```sql
SELECT count() FROM raw.boarding_records FINAL;
SELECT count() FROM raw.payment_transactions FINAL;
SELECT count() FROM raw.trips FINAL;
SELECT count() FROM raw.routes FINAL;

SELECT
    count() AS trip_rows,
    sum(calculated_passenger_count) AS total_passengers,
    sum(linked_trip_revenue) AS linked_trip_revenue
FROM marts.trip_operations_summary;

SELECT sum(total_revenue) AS total_successful_revenue
FROM marts.daily_revenue;
```

## Airflow

The `airflow/` directory contains a local Docker Compose setup based on Apache Airflow with CeleryExecutor, PostgreSQL, and Redis. It is not yet wired into the MVP pipeline through committed DAGs.

To use it later, add DAGs under:

```text
airflow/dags/
```

## Current Notes and Limitations

- Raw table DDL is not currently committed under `sql/raw/`; the raw tables are expected to already exist in ClickHouse.
- The extraction scripts use a fixed lower date bound of `2026-03-22` for the main operational tables, except routes, which are fully extracted.
- Inserts append into ClickHouse raw tables. Deduplication/versioning behavior depends on the raw table engines and schemas.
- `extract_buses.py` exists, but it is not part of the stable MVP runner yet.
- dbt and Airflow are present as project structure, not as the active production path.

## Common Commands

```bash
# Start platform services
cd /opt/busops-data/platform
docker compose --env-file ../.env up -d

# Stop platform services
cd /opt/busops-data/platform
docker compose --env-file ../.env down

# Test source and ClickHouse connections
cd /opt/busops-data
source .venv/bin/activate
python pipelines/test_connections.py

# Run the full MVP pipeline
cd /opt/busops-data
bash pipelines/run_mvp_pipeline.sh

# Open ClickHouse client
docker exec -it busops-clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" \
  --password "$CLICKHOUSE_PASSWORD"
```

## Operational Checklist

Before running the pipeline, confirm:

- `.env` exists and contains source database, ClickHouse, and Metabase settings.
- `busops-net` exists.
- `busops-clickhouse` is running.
- `.venv` exists and has the required Python packages installed.
- ClickHouse contains the expected `raw` tables and `marts` database.
- Source PostgreSQL is reachable from the host running the pipeline.

