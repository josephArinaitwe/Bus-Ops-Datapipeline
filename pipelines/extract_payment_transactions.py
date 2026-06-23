import os
import psycopg2
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv("/opt/busops-data/.env")

SOURCE_QUERY = """
SELECT
    id,
    user_id,
    ticket_id,
    pass_id,
    amount,
    currency,
    external_id,
    reference_id,
    payment_method,
    status,
    financial_transaction_id,
    franchise_id,
    created_at,
    updated_at,
    COALESCE(updated_at, created_at, NOW()) AS version_ts
FROM payment_transactions
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
    "user_id",
    "ticket_id",
    "pass_id",
    "amount",
    "currency",
    "external_id",
    "reference_id",
    "payment_method",
    "status",
    "financial_transaction_id",
    "franchise_id",
    "created_at",
    "updated_at",
    "version_ts",
]

if rows:
    clickhouse_client.insert(
        "raw.payment_transactions",
        rows,
        column_names=columns,
    )

print(f"Loaded {len(rows)} payment transactions into ClickHouse.")
