#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Bus Operations MVP Pipeline
# Purpose:
#   1. Extract source data from production PostgreSQL
#   2. Load into ClickHouse raw tables
#   3. Recreate ClickHouse marts/views
#   4. Run basic validation checks
#
# Location:
#   /opt/busops-data/pipelines/run_mvp_pipeline.sh
# ============================================================

PROJECT_DIR="/opt/busops-data"
ENV_FILE="${PROJECT_DIR}/.env"
VENV_DIR="${PROJECT_DIR}/.venv"
PIPELINES_DIR="${PROJECT_DIR}/pipelines"
MARTS_SQL="${PROJECT_DIR}/sql/marts/create_marts.sql"
LOG_DIR="${PROJECT_DIR}/logs"
RUN_LOG="${LOG_DIR}/mvp_pipeline.log"

mkdir -p "${LOG_DIR}"

echo "============================================================"
echo "Bus Ops MVP Pipeline Started: $(date)"
echo "============================================================"

cd "${PROJECT_DIR}"

# ------------------------------------------------------------
# 1. Check required files
# ------------------------------------------------------------

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: Missing environment file: ${ENV_FILE}"
  exit 1
fi

if [ ! -d "${VENV_DIR}" ]; then
  echo "ERROR: Missing Python virtual environment: ${VENV_DIR}"
  echo "Create it with: python3 -m venv /opt/busops-data/.venv"
  exit 1
fi

if [ ! -f "${MARTS_SQL}" ]; then
  echo "ERROR: Missing marts SQL file: ${MARTS_SQL}"
  exit 1
fi

# ------------------------------------------------------------
# 2. Load environment variables
# ------------------------------------------------------------

set -a
source "${ENV_FILE}"
set +a

if [ -z "${CLICKHOUSE_USER:-}" ]; then
  echo "ERROR: CLICKHOUSE_USER is not set in ${ENV_FILE}"
  exit 1
fi

if [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
  echo "ERROR: CLICKHOUSE_PASSWORD is not set in ${ENV_FILE}"
  exit 1
fi

# ------------------------------------------------------------
# 3. Check Docker containers
# ------------------------------------------------------------

echo ""
echo "Checking ClickHouse container..."

if ! docker ps --format '{{.Names}}' | grep -q '^busops-clickhouse$'; then
  echo "ERROR: busops-clickhouse container is not running."
  echo "Start it with:"
  echo "cd /opt/busops-data/platform && docker compose --env-file ../.env up -d"
  exit 1
fi

echo "ClickHouse container is running."

# ------------------------------------------------------------
# 4. Activate Python environment
# ------------------------------------------------------------

echo ""
echo "Activating Python virtual environment..."

source "${VENV_DIR}/bin/activate"

# ------------------------------------------------------------
# 5. Run extraction scripts
# ------------------------------------------------------------

run_script() {
  local script_name="$1"
  local script_path="${PIPELINES_DIR}/${script_name}"

  echo ""
  echo "Running ${script_name}..."

  if [ ! -f "${script_path}" ]; then
    echo "ERROR: Missing extraction script: ${script_path}"
    exit 1
  fi

  python "${script_path}"

  echo "Completed ${script_name}."
}

run_script "extract_boarding_records.py"
run_script "extract_payment_transactions.py"
run_script "extract_trips.py"
run_script "extract_routes.py"

# NOTE:
# We are intentionally not running extract_buses.py yet because raw.buses
# previously returned 0 rows and bus marts are not yet part of the stable MVP.

# ------------------------------------------------------------
# 6. Recreate marts
# ------------------------------------------------------------

echo ""
echo "Recreating ClickHouse marts..."

docker exec -i busops-clickhouse clickhouse-client \
  --user "${CLICKHOUSE_USER}" \
  --password "${CLICKHOUSE_PASSWORD}" \
  < "${MARTS_SQL}"

echo "Marts recreated successfully."

# ------------------------------------------------------------
# 7. Run validation checks
# ------------------------------------------------------------

echo ""
echo "Running validation checks..."

docker exec -i busops-clickhouse clickhouse-client \
  --user "${CLICKHOUSE_USER}" \
  --password "${CLICKHOUSE_PASSWORD}" <<'SQL'

SELECT
    'raw_boarding_records' AS check_name,
    count() AS records
FROM raw.boarding_records FINAL;

SELECT
    'raw_payment_transactions' AS check_name,
    count() AS records
FROM raw.payment_transactions FINAL;

SELECT
    'raw_trips' AS check_name,
    count() AS records
FROM raw.trips FINAL;

SELECT
    'raw_routes' AS check_name,
    count() AS records
FROM raw.routes FINAL;

SELECT
    'trip_operations_summary' AS check_name,
    count() AS trip_rows,
    sum(calculated_passenger_count) AS total_passengers,
    sum(linked_trip_revenue) AS linked_trip_revenue
FROM marts.trip_operations_summary;

SELECT
    'daily_revenue' AS check_name,
    sum(total_revenue) AS total_successful_revenue
FROM marts.daily_revenue;

SELECT
    'payment_status_summary' AS check_name,
    payment_status,
    transaction_count,
    total_amount
FROM marts.payment_status_summary
ORDER BY transaction_count DESC;

SQL

echo ""
echo "============================================================"
echo "Bus Ops MVP Pipeline Finished Successfully: $(date)"
echo "============================================================"
