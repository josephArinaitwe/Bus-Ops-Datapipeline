import os
import psycopg2
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv("/opt/busops-data/.env")

SOURCE_QUERY = """
SELECT
    id,
    trip_id,
    user_id,
    payment_txn_id,
    onboard_stage_id,
    verified_by_id,
    alighted_at,
    alight_stage_id,
    onboarded_at,
    seat_number,
    created_at,
    updated_at,
    status,
    alighting_distance,
    boarding_distance,
    passenger_name
FROM boarding_records
WHERE updated_at >  DATE '2026-03-22'
   OR created_at > DATE '2026-03-22';
"""

source_conn = psycopg2.connect(
    host=os.getenv("SOURCE_DB_HOST"),
    port=os.getenv("SOURCE_DB_PORT"),
    dbname=os.getenv("SOURCE_DB_NAME"),
    user=os.getenv("SOURCE_DB_USER"),
    password=os.getenv("SOURCE_DB_PASSWORD"),
)

clickhouse_client = clickhouse_connect.get_client(
    host="127.0.0.1",
    port=8123,
    username=os.getenv("CLICKHOUSE_USER"),
    password=os.getenv("CLICKHOUSE_PASSWORD"),
)

with source_conn.cursor() as cur:
    cur.execute(SOURCE_QUERY)
    rows = cur.fetchall()

columns = [
    "id",
    "trip_id",
    "user_id",
    "payment_txn_id",
    "onboard_stage_id",
    "verified_by_id",
    "alighted_at",
    "alight_stage_id",
    "onboarded_at",
    "seat_number",
    "created_at",
    "updated_at",
    "status",
    "alighting_distance",
    "boarding_distance",
    "passenger_name",
]

if rows:
    clickhouse_client.insert(
        "raw.boarding_records",
        rows,
        column_names=columns,
    )

print(f"Loaded {len(rows)} boarding records into ClickHouse.")
