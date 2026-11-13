#!/usr/bin/env bash
set -euo pipefail

# HW1 V2: reproducible additional measurements + read-only evidence collection.
# Never resets the primary soldout database or deletes Docker volumes.

root="$HOME/workspace/hse-repositories/system-design-hse-miem-2026-2027-public"
project="$root/soldout"
out=/tmp/soldout-hw1-evidence
source_bench="$HOME/Downloads/soldout-hw1-bench.sh"
patch1="$HOME/Downloads/soldout-hw1-v2-opt1-index.patch"
patch2="$HOME/Downloads/soldout-hw1-v2-opt2-counter.patch"
compose=(docker compose -f docker-compose.yml -f compose/lesson-02.yml -f compose/lesson-04.yml -f compose/lite.yml -f /tmp/soldout-hw1-ports.yml)

ensure_root() {
    [[ -d "$root/.git" && -d "$project" ]] || { echo "Missing repository: $root" >&2; exit 1; }
    cd "$root"
}

repeat_tests() {
    ensure_root
    for f in "$source_bench" "$patch1" "$patch2" /tmp/soldout-hw1-baseline.dump; do
        [[ -s "$f" ]] || { echo "Missing prerequisite: $f" >&2; exit 1; }
    done
    # HEAD must describe the true unoptimized V2 implementation. No git checkout/stash/reset.
    git cat-file -e 'HEAD:soldout/migrations/0022_dynamic_pricing.up.sql' || {
        echo "HEAD does not contain V2; cannot reconstruct a truthful baseline" >&2; exit 1;
    }
    if git cat-file -e 'HEAD:soldout/migrations/0023_confirmed_sector_index.up.sql' 2>/dev/null; then
        echo "HEAD already includes optimization 1; cannot reconstruct the original baseline from HEAD" >&2
        exit 1
    fi
    if git cat-file -e 'HEAD:soldout/migrations/0024_sector_sales_counter.up.sql' 2>/dev/null; then
        echo "HEAD already includes optimization 2; cannot reconstruct the original baseline from HEAD" >&2
        exit 1
    fi
    [[ -s /tmp/soldout-hw1-ports.yml ]] || {
        echo 'Create /tmp/soldout-hw1-ports.yml (postgres: ports: !reset []) first' >&2
        exit 1
    }
    mkdir -p "$out"
    local work
    work="$(mktemp -d /tmp/soldout-hw1-variants.XXXXXXXX)"
    echo "Isolated source snapshots: $work"
    for phase in base opt1 opt2; do
        mkdir -p "$work/$phase"
        git archive --format=tar HEAD soldout | tar -xf - -C "$work/$phase"
        [[ -f "$work/$phase/soldout/k6/v2.js" ]] || {
            echo "HEAD lacks k6/v2.js; source isn't the tested stage-2 baseline" >&2; exit 1;
        }
    done
    (cd "$work/opt1" && git apply --check "$patch1" && git apply "$patch1")
    (cd "$work/opt2" && git apply --check "$patch1" && git apply "$patch1" &&
        git apply --check "$patch2" && git apply "$patch2")

    # Adapt only the benchmark harness's source directory; keep its safety checks intact.
    python3 - "$source_bench" "$work/bench.sh" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
old = 'repo="$HOME/workspace/hse-repositories/system-design-hse-miem-2026-2027-public/soldout"'
new = 'repo="${SOLDOUT_REPO:-$HOME/workspace/hse-repositories/system-design-hse-miem-2026-2027-public/soldout}"'
if src.count(old) != 1:
    raise SystemExit('Benchmark harness changed: expected repository path occurs != 1 time')
pathlib.Path(sys.argv[2]).write_text(src.replace(old, new))
PY
    bash -n "$work/bench.sh"
    {
        echo "Baseline Git commit: $(git rev-parse HEAD)"
        sha256sum "$patch1" "$patch2" "$source_bench" /tmp/soldout-hw1-baseline.dump
        echo "Sources in: $work"
        echo "All benchmark DBs are separate soldout_hw1_* databases. Primary soldout DB is not restored."
    } > "$out/repeat-manifest.txt"

    # Runs 1 already exist, therefore perform independent repetitions 2 and 3.
    # Each phase gets its OWN source tree and a FRESH database from the identical dump.
    for rep in 2 3; do
        for phase in base opt1 opt2; do
            local result_dir="$out/v2-$phase-r$rep"
            if [[ -e "$result_dir/run-started.txt" ]]; then
                echo "Refusing to overwrite existing run: $result_dir" >&2
                exit 1
            fi
            mkdir -p "$result_dir"
            echo "=== $phase: run $rep, prepare ==="
            if ! SOLDOUT_REPO="$work/$phase/soldout" bash "$work/bench.sh" prepare "$phase" "$rep" > "$result_dir/prepare.log" 2>&1; then
                tail -n 60 "$result_dir/prepare.log" >&2
                echo "Prepare failed; no further variants started" >&2
                exit 1
            fi
            echo "=== $phase: run $rep, 30 purchases/s, 60s ==="
            if ! SOLDOUT_REPO="$work/$phase/soldout" bash "$work/bench.sh" run "$phase" "$rep" > "$result_dir/runner.log" 2>&1; then
                tail -n 90 "$result_dir/runner.log" >&2
                echo "Experiment failed; do not claim this variant is correct" >&2
                exit 1
            fi
            tail -n 2 "$result_dir/runner.log"
        done
    done
    echo "Repeated experiments completed. Run: bash ~/Downloads/hw1-evidence.sh collect"
}

collect_evidence() {
    ensure_root
    mkdir -p "$out/final-checks"
    local checks="$out/final-checks"
    {
        echo "Collected: $(date -Is)"
        echo "Branch: $(git branch --show-current)"
        echo "HEAD: $(git rev-parse HEAD)"
        echo "Tag lesson-5: $(git rev-parse lesson-5 2>/dev/null || echo absent)"
        echo '--- Branch ancestry ---'
        git merge-base --is-ancestor lesson-5 HEAD && echo 'lesson-5 ancestor: YES' || echo 'lesson-5 ancestor: NO'
        echo '--- Status ---'
        git status --short
        echo '--- Diff summary ---'
        git diff --stat
        echo '--- Latest commits ---'
        git log -8 --oneline --decorate
        echo '--- HW submission paths ---'
        git ls-files hw/hw1 soldout/spec soldout/docs/adr soldout/migrations | tail -n 70
        echo '--- Versions ---'
        go version
        docker --version
        docker compose version
    } > "$checks/repository.txt" 2>&1

    if git diff --check > "$checks/diff-check.txt" 2>&1; then
        echo PASS > "$checks/diff-check.exit"
    else
        echo FAIL > "$checks/diff-check.exit"
    fi
    cd "$project"
    if make lint-all > "$checks/lint-all.txt" 2>&1; then
        echo PASS > "$checks/lint-all.exit"
    else
        echo FAIL > "$checks/lint-all.exit"
    fi
    if make test > "$checks/test.txt" 2>&1; then
        echo PASS > "$checks/test.exit"
    else
        echo FAIL > "$checks/test.exit"
    fi
    if go test -race ./... -count=1 > "$checks/test-race.txt" 2>&1; then
        echo PASS > "$checks/test-race.exit"
    else
        echo FAIL > "$checks/test-race.exit"
    fi

    # READ-ONLY SQL against isolated experiment databases; never modify base 'soldout'.
    if [[ -s /tmp/soldout-hw1-ports.yml ]]; then
        "${compose[@]}" ps > "$checks/compose-ps.txt" 2>&1 || true
        for rep in 1 2 3; do
            for phase in base opt1 opt2; do
                local db="soldout_hw1_${phase}_r${rep}"
                if ! "${compose[@]}" exec -T postgres psql -U soldout -d postgres -Atqc \
                        "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null | grep -qx 1; then
                    echo "Missing DB $db" > "$checks/sql-$phase-r$rep.txt"
                    continue
                fi
                {
                    echo "=== $db ==="
                    "${compose[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -v ON_ERROR_STOP=1 <<'SQL'
SELECT version, dirty FROM schema_migrations;
SELECT status, count(*) AS holds FROM holds
WHERE event_id = '10000000-0000-4000-8000-000000000002'
GROUP BY status ORDER BY status;
SELECT sector_id, price_minor, count(*) AS confirmed_seats
FROM holds
WHERE event_id = '10000000-0000-4000-8000-000000000002'
  AND status = 'confirmed'
GROUP BY sector_id, price_minor ORDER BY sector_id, price_minor;
SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='public'
  AND tablename='holds' AND indexname LIKE '%confirmed%';
SQL
                    if [[ "$phase" == opt2 ]]; then
                        "${compose[@]}" exec -T postgres psql -U soldout -d "$db" -P pager=off -v ON_ERROR_STOP=1 <<'SQL'
WITH actual AS (
  SELECT event_id, sector_id, count(*)::bigint AS count
  FROM holds WHERE status = 'confirmed' GROUP BY 1,2
)
SELECT count(*) AS mismatch_count
FROM actual a FULL JOIN booking_sector_sales c USING(event_id, sector_id)
WHERE coalesce(a.count, 0) <> coalesce(c.sold_count, 0);
SQL
                    fi
                } > "$checks/sql-$phase-r$rep.txt" 2>&1
            done
        done
    else
        echo 'Missing /tmp/soldout-hw1-ports.yml: SQL evidence skipped' > "$checks/compose-ps.txt"
    fi

    python3 - "$out" <<'PY'
import json, statistics, sys
from pathlib import Path
root = Path(sys.argv[1])
phases = ('base', 'opt1', 'opt2')
rows = {}
notes = []
for phase in phases:
    data = []
    for rep in (1, 2, 3):
        d = root / f'v2-{phase}-r{rep}'
        fn = d / 'k6.json'
        if not fn.exists():
            notes.append(f'MISSING: {fn}')
            continue
        m = json.loads(fn.read_text())['metrics']
        get = lambda name, pct: m[f'http_req_duration{{name:{name}}}'][pct]
        d = {
            'run': rep,
            'paid': m.get('v2_paid', {}).get('count', 0),
            'checks_rate': m.get('checks', {}).get('value', 0),
            'errors': m.get('http_req_failed', {}).get('value', 1),
            'dropped': m.get('dropped_iterations', {}).get('count', -1),
            'hold_p50': get('hold','p(50)'), 'hold_p95': get('hold','p(95)'), 'hold_p99': get('hold','p(99)'),
            'order_p99': get('order','p(99)'), 'pay_p99': get('pay','p(99)'),
        }
        data.append(d)
    rows[phase] = data
output = [
    '# HW1 V2: reproducible comparison (k6, 30 iterations/s, 60 s)', '',
    '| Variant | Run | Paid | Checks | HTTP errors | Dropped | Hold p50 ms | Hold p95 ms | Hold p99 ms | Order p99 ms | Pay p99 ms |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|',
]
for phase in phases:
    for r in rows[phase]:
        output.append(f"| {phase} | {r['run']} | {r['paid']} | {r['checks_rate']:.3f} | "
                      f"{r['errors']:.4f} | {r['dropped']} | {r['hold_p50']:.2f} | "
                      f"{r['hold_p95']:.2f} | {r['hold_p99']:.2f} | {r['order_p99']:.2f} | {r['pay_p99']:.2f} |")
output += ['', '## Medians across independent runs', '',
           '| Variant | Runs | Hold p99 median ms | Order p99 median ms | Pay p99 median ms |',
           '|---|---:|---:|---:|---:|']
for phase in phases:
    data = rows[phase]
    if data:
        output.append(f"| {phase} | {len(data)} | {statistics.median(x['hold_p99'] for x in data):.2f} | "
                      f"{statistics.median(x['order_p99'] for x in data):.2f} | "
                      f"{statistics.median(x['pay_p99'] for x in data):.2f} |")
if rows['base']:
    base = statistics.median(x['hold_p99'] for x in rows['base'])
    output += ['', f'Baseline hold p99 median: {base:.3f} ms.']
    for phase in ('opt1','opt2'):
        if rows[phase]:
            new = statistics.median(x['hold_p99'] for x in rows[phase])
            output.append(f'{phase} hold p99 median change from base: {(new/base-1)*100:+.1f}% '
                          f'({"worse" if new>base else "better" if new<base else "unchanged"}).')
output += ['', '> These values measure end-to-end HTTP latency under a FIXED arrival rate; '
           'they do not establish maximum throughput or causal effects by themselves.',
           '> A partial index that makes p99 worse is an unsuccessful optimization for this workload.']
if notes:
    output += ['', '## Missing evidence', *('- ' + x for x in notes)]
(root / 'RESULTS.md').write_text('\n'.join(output) + '\n')
print('\n'.join(output))
PY
    {
        echo '=== Verification statuses ==='
        for x in diff-check lint-all test test-race; do
            echo "$x: $(cat "$checks/$x.exit")"
        done
        echo '=== Existing independent runs ==='
        for phase in base opt1 opt2; do
            for rep in 1 2 3; do
                d="$out/v2-$phase-r$rep"
                printf '%-18s ' "$phase-r$rep"
                if [[ -e "$d/exit-code.txt" ]]; then
                    printf 'exit=%s ' "$(cat "$d/exit-code.txt")"
                    grep -q 'Все инварианты соблюдены' "$d/invariants.txt" 2>/dev/null && printf 'invariants=PASS' || printf 'invariants=CHECK'
                else
                    printf 'NOT RUN'
                fi
                echo
            done
        done
    } | tee "$checks/STATUS.txt"
    # Exclude large database dumps and secrets; archive only reports and evidence.
    local archive=/tmp/soldout-hw1-submission-evidence.tar.gz
    tar -czf "$archive" -C /tmp soldout-hw1-evidence
    echo "Evidence archive: $archive"
    echo "Review comparison: $out/RESULTS.md"
}

case "${1:-}" in
    repeat) repeat_tests ;;
    collect) collect_evidence ;;
    *) echo "Usage: bash hw1-evidence.sh repeat|collect" >&2; exit 2 ;;
esac
