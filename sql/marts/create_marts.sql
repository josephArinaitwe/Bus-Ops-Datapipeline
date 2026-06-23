-- create_marts.sql
-- Bus Operations Analytics MVP Marts
-- Target: ClickHouse
--
-- Assumptions used in these marts:
-- 1. raw.boarding_records exists and uses statuses: 'onboarded', 'alighted'
-- 2. raw.payment_transactions exists and uses payment status: 'SUCCESSFUL'
-- 3. raw.trips exists and uses statuses such as: 'completed', 'in_progress'
-- 4. raw.routes exists and joins to trips using: trips.route_id = routes.route_id
-- 5. Zero UUID means "no ticket/pass/franchise reference":
--    00000000-0000-0000-0000-000000000000
--
-- Run with:
-- docker exec -i busops-clickhouse clickhouse-client \
--   --user busops_admin \
--   --password < /opt/busops-data/sql/marts/create_marts.sql


/* ============================================================
   1. Passenger count per trip
   Source: raw.boarding_records
   Grain: one row per trip_id
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_passenger_summary AS
SELECT
    trip_id,
    count() AS passenger_count,
    min(onboarded_at) AS first_boarding_time,
    max(onboarded_at) AS last_boarding_time
FROM raw.boarding_records FINAL
WHERE lowerUTF8(trimBoth(ifNull(status, ''), ' ')) IN ('onboarded', 'alighted')
  AND trip_id IS NOT NULL
GROUP BY trip_id;


/* ============================================================
   2. Payment status summary
   Source: raw.payment_transactions
   Grain: one row per payment status
   Purpose: monitoring successful vs failed transactions
   ============================================================ */

CREATE OR REPLACE VIEW marts.payment_status_summary AS
SELECT
    lowerUTF8(trimBoth(ifNull(status, ''), ' ')) AS payment_status,
    count() AS transaction_count,
    sum(ifNull(amount, 0)) AS total_amount
FROM raw.payment_transactions FINAL
GROUP BY payment_status;


/* ============================================================
   3. Daily revenue
   Source: raw.payment_transactions
   Grain: date + franchise + currency + payment method + revenue type
   Revenue rule:
     - SUCCESSFUL only counts as collected revenue
     - pass_id != zero_uuid  => pass revenue
     - ticket_id != zero_uuid => ticket revenue
     - both zero_uuid/null    => wallet revenue
   ============================================================ */

CREATE OR REPLACE VIEW marts.daily_revenue AS
WITH toUUID('00000000-0000-0000-0000-000000000000') AS zero_uuid
SELECT
    nullIf(ifNull(franchise_id, zero_uuid), zero_uuid) AS franchise_id,

    toDate(coalesce(created_at, updated_at, version_ts)) AS revenue_date,

    ifNull(currency, 'UGX') AS currency,

    upperUTF8(trimBoth(ifNull(payment_method, 'UNKNOWN'), ' ')) AS payment_method,

    multiIf(
        ifNull(pass_id, zero_uuid) != zero_uuid, 'pass',
        ifNull(ticket_id, zero_uuid) != zero_uuid, 'ticket',
        'wallet'
    ) AS revenue_type,

    count() AS successful_transactions,
    sum(ifNull(amount, 0)) AS total_revenue

FROM raw.payment_transactions FINAL
WHERE lowerUTF8(trimBoth(ifNull(status, ''), ' ')) = 'successful'
GROUP BY
    franchise_id,
    revenue_date,
    currency,
    payment_method,
    revenue_type;


/* ============================================================
   4. Revenue by type
   Source: raw.payment_transactions
   Grain: one row per revenue type
   ============================================================ */

CREATE OR REPLACE VIEW marts.revenue_by_type AS
WITH toUUID('00000000-0000-0000-0000-000000000000') AS zero_uuid
SELECT
    multiIf(
        ifNull(pass_id, zero_uuid) != zero_uuid, 'pass',
        ifNull(ticket_id, zero_uuid) != zero_uuid, 'ticket',
        'wallet'
    ) AS revenue_type,

    count() AS successful_transactions,
    sum(ifNull(amount, 0)) AS total_revenue

FROM raw.payment_transactions FINAL
WHERE lowerUTF8(trimBoth(ifNull(status, ''), ' ')) = 'successful'
GROUP BY revenue_type;


/* ============================================================
   5. Revenue by franchise ID
   Source: marts.daily_revenue
   Grain: one row per franchise_id
   ============================================================ */

CREATE OR REPLACE VIEW marts.revenue_by_franchise AS
SELECT
    franchise_id,
    sum(successful_transactions) AS successful_transactions,
    sum(total_revenue) AS total_revenue
FROM marts.daily_revenue
GROUP BY franchise_id;


/* ============================================================
   6. Route context
   Source: raw.routes
   Join rule confirmed:
     trips.route_id = routes.route_id
   Grain: one row per route_id
   ============================================================ */

CREATE OR REPLACE VIEW marts.route_context AS
SELECT
    route_id AS route_join_id,
    route_id,
    route_code,
    name AS route_name,

    start_stage_name,
    end_stage_name,

    distance_km,
    fare_amount,
    max_fare,
    price_km,

    city_id,
    destination_city_id,

    number_of_stages,

    lowerUTF8(trimBoth(ifNull(status, 'unknown'), ' ')) AS route_status,
    lowerUTF8(trimBoth(ifNull(deployment_type, 'unknown'), ' ')) AS deployment_type,

    franchise_id
FROM raw.routes FINAL
WHERE deleted_at IS NULL;


/* ============================================================
   7. Trip context
   Source: raw.trips
   Grain: one row per trip
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_context AS
SELECT
    id AS trip_id,
    bus_id,
    route_id,
    driver_id,
    conductor_id,

    departure_time,
    arrival_time,

    toDate(coalesce(created_at, updated_at, version_ts)) AS trip_date,

    lowerUTF8(trimBoth(ifNull(status, 'unknown'), ' ')) AS trip_status,

    passenger_count AS recorded_passenger_count,
    total_passengers_carried,

    start_mileage,
    end_mileage,
    distance_covered,

    lowerUTF8(trimBoth(ifNull(direction, 'unknown'), ' ')) AS direction,
    lowerUTF8(trimBoth(ifNull(billing_method, 'unknown'), ' ')) AS billing_method,

    franchise_id,

    created_at,
    updated_at,
    version_ts
FROM raw.trips FINAL;


/* ============================================================
   8. Trip revenue summary
   Sources:
     raw.boarding_records
     raw.payment_transactions
   Grain: one row per trip_id
   Note:
     This is linked trip revenue through boarding_records.payment_txn_id.
     It may not capture all pass revenue allocation logic.
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_revenue_summary AS
SELECT
    trip_id,
    count() AS successful_payment_transactions,
    sum(amount) AS linked_trip_revenue
FROM
(
    SELECT DISTINCT
        br.trip_id AS trip_id,
        pt.id AS payment_transaction_id,
        ifNull(pt.amount, 0) AS amount
    FROM
    (
        SELECT *
        FROM raw.boarding_records FINAL
    ) AS br
    INNER JOIN
    (
        SELECT *
        FROM raw.payment_transactions FINAL
    ) AS pt
        ON pt.id = br.payment_txn_id
    WHERE lowerUTF8(trimBoth(ifNull(br.status, ''), ' ')) IN ('onboarded', 'alighted')
      AND lowerUTF8(trimBoth(ifNull(pt.status, ''), ' ')) = 'successful'
      AND br.trip_id IS NOT NULL
)
GROUP BY trip_id;


/* ============================================================
   9. Basic passenger + revenue summary
   Sources:
     marts.trip_passenger_summary
     marts.trip_revenue_summary
   Grain: one row per trip_id
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_passenger_revenue_summary AS
SELECT
    p.trip_id,
    p.passenger_count,
    p.first_boarding_time,
    p.last_boarding_time,
    ifNull(r.successful_payment_transactions, 0) AS successful_payment_transactions,
    ifNull(r.linked_trip_revenue, 0) AS linked_trip_revenue
FROM marts.trip_passenger_summary AS p
LEFT JOIN marts.trip_revenue_summary AS r
    ON r.trip_id = p.trip_id;


/* ============================================================
   10. Main trip operations summary
   Sources:
     marts.trip_context
     marts.trip_passenger_summary
     marts.trip_revenue_summary
   Grain: one row per trip
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_operations_summary AS
SELECT
    t.trip_id,
    t.trip_date,

    t.route_id,
    t.bus_id,
    t.driver_id,
    t.conductor_id,
    t.franchise_id,

    t.departure_time,
    t.arrival_time,
    t.trip_status,
    t.direction,
    t.billing_method,

    t.recorded_passenger_count,
    t.total_passengers_carried,

    ifNull(p.passenger_count, 0) AS calculated_passenger_count,
    p.first_boarding_time,
    p.last_boarding_time,

    ifNull(r.successful_payment_transactions, 0) AS successful_payment_transactions,
    ifNull(r.linked_trip_revenue, 0) AS linked_trip_revenue,

    t.start_mileage,
    t.end_mileage,
    t.distance_covered

FROM marts.trip_context AS t
LEFT JOIN marts.trip_passenger_summary AS p
    ON p.trip_id = t.trip_id
LEFT JOIN marts.trip_revenue_summary AS r
    ON r.trip_id = t.trip_id;


/* ============================================================
   11. Daily operations summary
   Source: marts.trip_operations_summary
   Grain: date + franchise
   ============================================================ */

CREATE OR REPLACE VIEW marts.daily_operations_summary AS
SELECT
    trip_date,
    franchise_id,

    count() AS total_trips,
    countIf(trip_status = 'completed') AS completed_trips,
    countIf(trip_status = 'in_progress') AS in_progress_trips,

    sum(calculated_passenger_count) AS total_passengers,

    sum(successful_payment_transactions) AS successful_payment_transactions,
    sum(linked_trip_revenue) AS linked_trip_revenue,

    round(avg(calculated_passenger_count), 2) AS avg_passengers_per_trip

FROM marts.trip_operations_summary
GROUP BY
    trip_date,
    franchise_id;


/* ============================================================
   12. Route-enriched trip operations summary
   Source:
     marts.trip_operations_summary
     marts.route_context
   Grain: one row per trip
   Note:
     This excludes bus plate/fleet details for now because raw.buses
     was not yet confirmed as successfully loaded.
   ============================================================ */

CREATE OR REPLACE VIEW marts.trip_operations_route_enriched AS
SELECT
    t.trip_id,
    t.trip_date,

    t.franchise_id,

    t.route_id,
    r.route_code,
    r.route_name,
    r.start_stage_name,
    r.end_stage_name,

    t.bus_id,
    t.driver_id,
    t.conductor_id,

    t.departure_time,
    t.arrival_time,
    t.trip_status,
    t.direction,
    t.billing_method,

    t.recorded_passenger_count,
    t.total_passengers_carried,
    t.calculated_passenger_count,

    t.successful_payment_transactions,
    t.linked_trip_revenue,

    t.start_mileage,
    t.end_mileage,
    t.distance_covered

FROM marts.trip_operations_summary AS t
LEFT JOIN marts.route_context AS r
    ON r.route_join_id = t.route_id;


/* ============================================================
   13. Route performance summary
   Source: marts.trip_operations_route_enriched
   Grain: date + franchise + route
   ============================================================ */

CREATE OR REPLACE VIEW marts.route_performance_summary AS
SELECT
    trip_date,
    franchise_id,

    route_id,
    route_code,
    route_name,

    count() AS total_trips,
    countIf(trip_status = 'completed') AS completed_trips,
    countIf(trip_status = 'in_progress') AS in_progress_trips,

    sum(calculated_passenger_count) AS total_passengers,
    sum(linked_trip_revenue) AS linked_trip_revenue,

    round(avg(calculated_passenger_count), 2) AS avg_passengers_per_trip

FROM marts.trip_operations_route_enriched
GROUP BY
    trip_date,
    franchise_id,
    route_id,
    route_code,
    route_name;


/* ============================================================
   14. Basic validation queries
   These are SELECT statements only.
   They will print useful totals when the script is run.
   ============================================================ */

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


