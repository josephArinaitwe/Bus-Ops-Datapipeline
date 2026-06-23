import os
import json
import psycopg2
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv("/opt/busops-data/.env")

SOURCE_QUERY = """
SELECT
    route_id,
    route_code,
    name,

    distance_km,
    fare_amount,

    city_id,
    stage_ids::text AS stage_ids,

    created_at,
    updated_at,

    deployment_type,
    number_of_stages,
    max_fare,

    destination_city_id,
    start_stage_name,
    end_stage_name,

    status,

    start_coordinates::text AS start_coordinates,
    end_coordinates::text AS end_coordinates,

    deleted_at,
    stage_buffer,
    price_km,

    franchise_id,

    COALESCE(updated_at, created_at, NOW()) AS version_ts
FROM routes;
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
    "route_id",
    "route_code",
    "name",

    "distance_km",
    "fare_amount",

    "city_id",
    "stage_ids",

    "created_at",
    "updated_at",

    "deployment_type",
    "number_of_stages",
    "max_fare",

    "destination_city_id",
    "start_stage_name",
    "end_stage_name",

    "status",

    "start_coordinates",
    "end_coordinates",

    "deleted_at",
    "stage_buffer",
    "price_km",

    "franchise_id",

    "version_ts",
]

if rows:
    clickhouse_client.insert(
        "raw.routes",
        rows,
        column_names=columns,
    )

print(f"Loaded {len(rows)} routes into ClickHouse.")
