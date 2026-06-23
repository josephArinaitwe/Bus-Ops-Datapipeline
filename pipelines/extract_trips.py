import os
import psycopg2
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv("/opt/busops-data/.env")

SOURCE_QUERY = """
SELECT
    id,
    bus_id,
    route_id,
    driver_id,
    conductor_id,
    departure_time,
    arrival_time,
    created_at,
    updated_at,
    status::text AS status,
    passenger_count,
    total_passengers_carried,
    start_mileage,
    end_mileage,
    distance_covered,
    direction::text AS direction,
    billing_method::text AS billing_method,
    franchise_id,
    COALESCE(updated_at, created_at, NOW()) AS version_ts
FROM trips
WHERE created_at >= DATE '2026-03-22'
   OR updated_at >= DATE '2026-03-22';
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
    "bus_id",
    "route_id",
    "driver_id",
    "conductor_id",
    "departure_time",
    "arrival_time",
    "created_at",
    "updated_at",
    "status",
    "passenger_count",
    "total_passengers_carried",
    "start_mileage",
    "end_mileage",
    "distance_covered",
    "direction",
    "billing_method",
    "franchise_id",
    "version_ts",
]

if rows:
    clickhouse_client.insert(
        "raw.trips",
        rows,
        column_names=columns,
    )

print(f"Loaded {len(rows)} trips into ClickHouse.")

