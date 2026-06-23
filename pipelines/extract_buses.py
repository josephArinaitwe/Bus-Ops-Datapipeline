import os
import psycopg2
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv("/opt/busops-data/.env")

SOURCE_QUERY = """
SELECT
    id,
    bus_type_id,
    city_id,
    plate_number,
    fleet_number,
    capacity,
    standing,
    seating,
    has_ac,
    has_wifi,
    created_at,
    updated_at,
    status::text AS status,
    franchise_id,
    COALESCE(updated_at, created_at, NOW()) AS version_ts
FROM buses;
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
    "bus_type_id",
    "city_id",
    "plate_number",
    "fleet_number",
    "capacity",
    "standing",
    "seating",
    "has_ac",
    "has_wifi",
    "created_at",
    "updated_at",
    "status",
    "franchise_id",
    "version_ts",
]

if rows:
    clickhouse_client.insert(
        "raw.buses",
        rows,
        column_names=columns,
    )

print(f"Loaded {len(rows)} buses into ClickHouse.")
