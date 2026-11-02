#!/bin/bash
# Time ClickBench queries on the exact (unmodified) PostgreSQL. Results go to a CSV that is
# appended after EVERY run, so a killed job still leaves partial data.
#
#   bash scripts/run_baseline.sh                       # PilotDB paper's 7 queries, 10 runs each
#   QUERIES=all RUNS=3 bash scripts/run_baseline.sh    # all 43 queries
#   QUERIES="1 2 3 21" bash scripts/run_baseline.sh    # any subset (line numbers, 1-based)
#   RESTART_BETWEEN=1 bash scripts/run_baseline.sh     # restart Postgres before each query
#
# Default query set: ids 1 2 3 4 8 21 30, taken from the authors' script
# experiments/query_speedups/run_pilotdb_clickhouse.sh (assumes 1-based ids; verify in evaluate.py).
#
# Needs a running server (scripts/setup_postgres.sh) with the `hits` table loaded.
#
# Cache caveat: RESTART_BETWEEN=1 only empties PostgreSQL's shared_buffers. The OS page cache
# stays warm (dropping it needs root, which PACE users don't have). Whatever you choose, state
# it in the report. Column `run` is kept so you can treat run 1 as "cold-ish" and runs 2+ as warm.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
activate_pg || exit 1

REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUERY_FILE="${QUERY_FILE:-$CLICKBENCH_DIR/postgresql/queries.sql}"
RUNS="${RUNS:-10}"
QUERIES="${QUERIES:-1 2 3 4 8 21 30}"
RESTART_BETWEEN="${RESTART_BETWEEN:-0}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-0}"   # ms; 0 = no limit
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/results}"
TAG="${TAG:-$(date +%Y%m%d_%H%M%S)}"
MODE="${MODE:-exact}"
OUT="$RESULTS_DIR/baseline_${TAG}.csv"
ERRLOG="$RESULTS_DIR/baseline_${TAG}_errors.log"
ENVFILE="$RESULTS_DIR/baseline_${TAG}_env.txt"
NODE="$(hostname)"

[ -f "$QUERY_FILE" ] || { echo "ERROR: query file not found: $QUERY_FILE" >&2; exit 1; }
psql -X -Atc 'select 1' >/dev/null 2>&1 || { echo "ERROR: cannot connect. Is the server running? (bash scripts/setup_postgres.sh)" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"

# One query per line; skip blank lines. The query id is its position among non-blank lines.
mapfile -t ALL < <(tr -d '\r' < "$QUERY_FILE" | grep -v '^[[:space:]]*$')
echo ">> ${#ALL[@]} queries in $QUERY_FILE"

want() {
  [ "$QUERIES" = "all" ] && return 0
  case " $QUERIES " in *" $1 "*) return 0 ;; esac
  return 1
}

{
  echo "start_utc: $(date -u +%FT%TZ)"
  echo "node: $NODE   slurm_job: ${SLURM_JOB_ID:-none}   cpus_allocated: ${SLURM_CPUS_ON_NODE:-unknown}   nproc: $(nproc 2>/dev/null || echo ?)"
  free -g 2>/dev/null | head -2 || true
  echo "RUNS=$RUNS QUERIES=$QUERIES RESTART_BETWEEN=$RESTART_BETWEEN STATEMENT_TIMEOUT=$STATEMENT_TIMEOUT MODE=$MODE"
  echo "query_file: $QUERY_FILE"
  psql -X -Atc 'select version()'
  echo "hits rows: $(psql -X -Atc 'select count(*) from hits')"
  psql -X -Atc "select name || ' = ' || setting || coalesce(unit, '') from pg_settings where name in ('shared_buffers','work_mem','effective_cache_size','max_parallel_workers_per_gather','max_parallel_workers','max_wal_size','maintenance_work_mem','jit') order by name"
} > "$ENVFILE" 2>&1
echo ">> Environment snapshot: $ENVFILE"

[ -s "$OUT" ] || echo "mode,query_id,run,time_ms,status,node,utc_time" > "$OUT"
echo ">> Writing $OUT"

time_query() {   # $1 = SQL. Sets MS and STATUS.
  local out rc
  out=$(PGOPTIONS="-c statement_timeout=$STATEMENT_TIMEOUT" psql -X -t -v ON_ERROR_STOP=1 -c '\timing on' -c "$1" 2>&1)
  rc=$?
  MS=$(printf '%s\n' "$out" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -n1)
  if [ "$rc" -ne 0 ]; then
    STATUS=error; MS=""
    printf 'query %s run %s: %s\n' "$QID" "$RUN" "$(printf '%s\n' "$out" | grep -v '^Time:' | head -n 3)" >> "$ERRLOG"
  elif [ -z "$MS" ]; then
    STATUS=no_timing
  else
    STATUS=ok
  fi
}

for i in "${!ALL[@]}"; do
  QID=$((i + 1))
  want "$QID" || continue
  if [ "$RESTART_BETWEEN" = "1" ]; then
    pg_down >/dev/null 2>&1
    pg_up >/dev/null 2>&1 || { echo "ERROR: restart failed" >&2; exit 1; }
  fi
  for RUN in $(seq 1 "$RUNS"); do
    time_query "${ALL[$i]}"
    echo "$MODE,$QID,$RUN,$MS,$STATUS,$NODE,$(date -u +%FT%TZ)" >> "$OUT"
    printf 'Q%-2s run %s: %s ms [%s]\n' "$QID" "$RUN" "${MS:-NA}" "$STATUS"
    [ "$STATUS" = "ok" ] || break   # don't repeat a failing/timeout query
  done
done

echo ">> Done. Results: $OUT"
if [ -s "$ERRLOG" ]; then echo ">> Some queries failed, see $ERRLOG"; fi
