#!/usr/bin/env bash
set -euo pipefail

# A temporary, non-destructive benchmark harness for soldout HW1 V2.
# All changes outside the repository are limited to the soldout Docker Compose
# project, its PostgreSQL instance (three NEW databases), and files in /tmp.

repo="$HOME/workspace/hse-repositories/system-design-hse-miem-2026-2027-public/soldout"
cd "$repo"

base=(docker compose
    -f docker-compose.yml
    -f compose/lesson-02.yml
    -f compose/lesson-04.yml
    -f compose/lite.yml
    -f /tmp/soldout-hw1-ports.yml)
bench=("${base[@]}" -f /tmp/soldout-hw1-bench.yml)
dump=/tmp/soldout-hw1-baseline.dump
out=/tmp/soldout-hw1-evidence
phase="${2:-}"
rep="${3:-1}"

usage() {
    echo "Usage: bash soldout-hw1-bench.sh prepare|run base|opt1|opt2 [run_number]" >&2
    echo "       bash soldout-hw1-bench.sh restore-original" >&2
    exit 2
}

if [[ "${1:-}" != restore-original ]]; then
    case "$phase" in base|opt1|opt2) ;; *) usage ;; esac
    [[ "$rep" =~ ^[1-9][0-9]*$ ]] || usage
fi

if [[ ! -f /tmp/soldout-hw1-ports.yml ]]; then
    cat > /tmp/soldout-hw1-ports.yml <<'YAML'
services:
  postgres:
    ports: !reset []
YAML
fi

if [[ "${1:-}" == restore-original ]]; then
    # Starting the newest binary against the original database can automatically
    # apply new migrations. Never modify the original schema without explicit opt-in.
    original_version="$("${base[@]}" exec -T postgres psql -U soldout -d soldout -Atqc \
        'SELECT version FROM schema_migrations')"
    latest_migration="$(find migrations -maxdepth 1 -name '*.up.sql' -printf '%f\n' | sed -E 's/^0*([0-9]+)_.*/\1/' | sort -n | tail -1)"
    if (( 10#$original_version < 10#$latest_migration )) && [[ "${ALLOW_ORIGINAL_MIGRATIONS:-0}" != 1 ]]; then
        echo "REFUSING: original database schema $original_version is older than application migration $latest_migration." >&2
        echo "Keep the test service running, or explicitly opt in with ALLOW_ORIGINAL_MIGRATIONS=1 after reviewing the migrations." >&2
        exit 1
    fi
    "${base[@]}" up -d --no-deps --force-recreate --wait soldout notifier
    if [[ -f /tmp/soldout-hw1-bench.yml ]]; then
        "${bench[@]}" stop pgbouncer-hw1 valkey-hw1 || true
    fi
    "${base[@]}" ps
    exit 0
fi

db="soldout_hw1_${phase}_r${rep}"
name="v2-${phase}-r${rep}"
mkdir -p "$out/$name" k6/results

generate_override() {
    sed "s/^soldout = host=postgres port=5432 dbname=soldout$/soldout = host=postgres port=5432 dbname=${db}/" \
        compose/pgbouncer/pgbouncer.ini > /tmp/soldout-hw1-pgbouncer.ini
    grep -Fx "soldout = host=postgres port=5432 dbname=${db}" \
        /tmp/soldout-hw1-pgbouncer.ini >/dev/null
    cat > /tmp/soldout-hw1-bench.yml <<YAML
services:
  pgbouncer-hw1:
    image: edoburu/pgbouncer:latest
    cpus: 0.5
    volumes:
      - /tmp/soldout-hw1-pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - $repo/compose/pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U soldout"]
      interval: 2s
      timeout: 3s
      retries: 30
  valkey-hw1:
    image: valkey/valkey:9-alpine
    cpus: 0.5
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 30
  soldout:
    environment:
      DATABASE_URL: postgres://soldout:soldout@pgbouncer-hw1:6432/soldout?sslmode=disable
      DATABASE_URL_DIRECT: postgres://soldout:soldout@postgres:5432/${db}?sslmode=disable&options=-c%20statement_timeout%3D0
      VALKEY_ADDR: valkey-hw1:6379
      MIGRATE_ON_START: "true"
      SEED_ON_START: "false"
      SEED_SEATS_PER_EVENT: "4000"
    depends_on:
      pgbouncer-hw1:
        condition: service_healthy
      valkey-hw1:
        condition: service_healthy
  notifier:
    environment:
      DATABASE_URL: postgres://soldout:soldout@postgres:5432/${db}?sslmode=disable
  invariants:
    environment:
      DATABASE_URL: postgres://soldout:soldout@postgres:5432/${db}?sslmode=disable
YAML
}

check_bench_connection() {
    local actual
    actual="$("${bench[@]}" exec -T -e PGPASSWORD=soldout pgbouncer-hw1 \
        psql -h 127.0.0.1 -p 6432 -U soldout -d soldout -Atqc 'SELECT current_database()')"
    [[ "$actual" == "$db" ]] || {
        echo "ERROR: pgbouncer-hw1 points to '$actual' instead of '$db'" >&2
        exit 1
    }
}

case "${1:-}" in
    prepare)
        [[ -s "$dump" ]] || { echo "Missing database snapshot $dump" >&2; exit 1; }
        exists="$("${base[@]}" exec -T postgres psql -U soldout -d postgres -Atqc \
            "SELECT count(*) FROM pg_database WHERE datname = '$db'")"
        [[ "$exists" == 0 ]] || { echo "Benchmark DB already exists: $db (not overwriting)" >&2; exit 1; }
        "${base[@]}" exec -T postgres createdb -U soldout --owner=soldout --template=template0 "$db"
        "${base[@]}" exec -T postgres pg_restore -U soldout -d "$db" \
            --no-owner --no-privileges < "$dump"
        generate_override
        "${bench[@]}" config --quiet
        "${bench[@]}" up -d --no-deps --force-recreate --wait pgbouncer-hw1 valkey-hw1
        "${bench[@]}" build soldout notifier
        "${bench[@]}" up -d --no-deps --force-recreate --wait soldout notifier
        check_bench_connection
        "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -v ON_ERROR_STOP=1 \
            -c "ANALYZE holds; ANALYZE catalog_seat_state;" >/dev/null
        got="$("${bench[@]}" exec -T postgres psql -U soldout -d "$db" -Atqc \
            "SELECT count(*) FROM holds WHERE event_id = '10000000-0000-4000-8000-000000000002'")"
        [[ "$got" == 0 ]] || { echo "ERROR: $db is not empty for event 2 ($got holds)" >&2; exit 1; }
        version="$("${bench[@]}" exec -T postgres psql -U soldout -d "$db" -Atqc \
            'SELECT version FROM schema_migrations')"
        echo "$version" | tee "$out/$name/schema-version.txt"
        case "$phase:$version" in base:22|opt1:23|opt2:24) ;; \
            *) echo "ERROR: expected schema version 22/23/24 for base/opt1/opt2, got $version" >&2; exit 1 ;; \
        esac
        echo "Ready: $name, database=$db. Saved original database is untouched."
        ;;
    run)
        [[ -f /tmp/soldout-hw1-bench.yml ]] || { echo "Run prepare first" >&2; exit 1; }
        check_bench_connection
        current="$("${bench[@]}" exec -T postgres psql -U soldout -d "$db" -Atqc \
            "SELECT count(*) FROM holds WHERE event_id = '10000000-0000-4000-8000-000000000002'")"
        [[ "$current" == 0 ]] || { echo "ERROR: event 2 already has $current holds; use a NEW run number" >&2; exit 1; }
        [[ ! -e "$out/$name/run-started.txt" ]] || { echo "ERROR: $name was already executed" >&2; exit 1; }
        date -Is > "$out/$name/run-started.txt"
        "${bench[@]}" exec -T postgres psql -U soldout -d soldout -v ON_ERROR_STOP=1 -Atqc \
            "SELECT pg_stat_statements_reset(0, (SELECT oid FROM pg_database WHERE datname = '$db'), 0)" >/dev/null
        (
            sleep 5
            make pprof-top PROFILES= STEP="$name" COMPOSE="${bench[*]}"
        ) </dev/null > "$out/$name/pprof-command.log" 2>&1 &
        pprof_pid=$!
        (
            sleep 10
            for n in 1 2 3 4; do
                "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
                    "SELECT state, wait_event_type, wait_event, count(*)
                     FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()
                     GROUP BY 1,2,3 ORDER BY 4 DESC;"
                sleep 10
            done
        ) </dev/null > "$out/$name/pg-activity.log" 2>&1 &
        pg_pid=$!
        (
            sleep 20
            make traces-slow COMPOSE="${bench[*]}" \
                Q='{ name = "POST /v1/orders/{id}/pay" && duration > 250ms }'
        ) </dev/null > "$out/$name/traces-slow.txt" 2>&1 &
        trace_pid=$!
        set +e
        "${bench[@]}" --profile load run --rm --no-deps \
            -T --interactive=false --user "$(id -u):$(id -g)" \
            -e EVENT_ID=10000000-0000-4000-8000-000000000002 \
            -e V2_RATE=30 -e V2_DURATION=60s \
            k6 run --summary-export="/results/$name.json" /scripts/v2.js \
            2>&1 | tee "$out/$name/k6.log"
        rc="${PIPESTATUS[0]}"
        set -e
        wait "$pprof_pid" || true
        wait "$pg_pid" || true
        wait "$trace_pid" || true
        "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
            "SELECT calls, round(total_exec_time::numeric, 2) AS total_ms,
                    round(mean_exec_time::numeric, 4) AS mean_ms, rows,
                    left(regexp_replace(query, E'\\s+', ' ', 'g'), 120) AS query
             FROM pg_stat_statements
             WHERE dbid = (SELECT oid FROM pg_database WHERE datname = '$db')
               AND query NOT LIKE '%pg_stat_statements%'
             ORDER BY total_exec_time DESC LIMIT 15;" > "$out/$name/pg-top.txt"
        invariant_ok=0
        for n in 1 2 3 4 5 6 7 8 9 10; do
            if make invariants COMPOSE="${bench[*]}" > "$out/$name/invariants.txt" 2>&1; then
                invariant_ok=1
                break
            fi
            sleep 2
        done
        "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
            "SELECT calls, round(total_exec_time::numeric,2) AS total_ms,
                round(mean_exec_time::numeric,4) AS mean_ms, query
              FROM pg_stat_statements
              WHERE dbid = (SELECT oid FROM pg_database WHERE datname = '$db')
                AND (query LIKE '%booking.count_sector_sales%'
                  OR query LIKE '%booking.get_sector_sales%'
                  OR query LIKE '%booking.increment_sector_sales%')
              ORDER BY total_exec_time DESC" \
            > "$out/$name/pricing-sql.txt"
        "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
            "EXPLAIN (ANALYZE, BUFFERS)
             SELECT count(*) FROM holds
             WHERE event_id = '10000000-0000-4000-8000-000000000002'
               AND sector_id = '30000000-0000-4000-8000-0000000007d1'
               AND status = 'confirmed';" > "$out/$name/explain-count.txt"
        "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
            "SELECT sector_id, count(*) AS paid_seats,
                    min(price_minor) AS min_price_minor,
                    max(price_minor) AS max_price_minor
             FROM holds
             WHERE event_id = '10000000-0000-4000-8000-000000000002'
               AND status = 'confirmed'
             GROUP BY sector_id ORDER BY sector_id;" > "$out/$name/price-tiers.txt"
        if [[ "$phase" == opt2 ]]; then
            "${bench[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -c \
                "EXPLAIN (ANALYZE, BUFFERS)
                 SELECT sold_count FROM booking_sector_sales
                 WHERE event_id = '10000000-0000-4000-8000-000000000002'
                   AND sector_id = '30000000-0000-4000-8000-0000000007d1';" \
                > "$out/$name/explain-counter.txt"
        fi
        if [[ -f "k6/results/pprof-top-$name.txt" ]]; then
            cp "k6/results/pprof-top-$name.txt" "$out/$name/pprof-top.txt"
        fi
        if [[ -f "k6/results/$name.json" ]]; then
            cp "k6/results/$name.json" "$out/$name/k6.json"
        fi
        echo "$rc" > "$out/$name/exit-code.txt"
        echo "k6 exit code: $rc; invariant_ok: $invariant_ok; evidence: $out/$name"
        [[ "$invariant_ok" == 1 ]] || exit 1
        exit "$rc"
        ;;
    *) usage ;;
esac
