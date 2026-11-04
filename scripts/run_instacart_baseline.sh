#!/bin/bash
# Time the Instacart queries on exact (unmodified) PostgreSQL. Same output format as
# run_baseline.sh, but reads one query per FILE (query_<id>.sql) and keeps <id> as the query id.
#
#   bash scripts/run_instacart_baseline.sh                  # all queries, 3 runs each
#   RUNS=5 QUERIES="1 3 19" bash scripts/run_instacart_baseline.sh
#   QUERY_DIR=/path/to/queries bash scripts/run_instacart_baseline.sh
#
# Needs a running server (scripts/setup_postgres.sh) with the instacart database loaded
# (scripts/load_instacart.sh, then optionally scripts/scale_instacart.sh).
#
# Cache caveat (same as run_baseline.sh): we have no root on PACE, so the OS page cache is not
# dropped. RESTART_BETWEEN=1 only empties shared_buffers. Treat run 1 as cold-ish, runs 2+ as warm.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
export PGDATABASE="${INSTACART_DB:-instacart}"   # override env.sh's clickbench default
activate_pg || exit 1

REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUERY_DIR="${QUERY_DIR:-$REPO_DIR/benchmarks/postgres/instacart}"
RUNS="${RUNS:-3}"
QUERIES="${QUERIES:-all}"
RESTART_BETWEEN="${RESTART_BETWEEN:-0}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-0}"   # ms; 0 = no limit
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/results}"
TAG="${TAG:-instacart_$(date +%Y%m%d_%H%M%S)}"
MODE="${MODE:-exact}"
OUT="$RESULTS_DIR/baseline_${TAG}.csv"
ERRLOG="$RESULTS_DIR/baseline_${TAG}_errors.log"
ENVFILE="$RESULTS_DIR/baseline_${TAG}_env.txt"
NODE="$(hostname)"

[ -d "$QUERY_DIR" ] || { echo "ERROR: query dir not found: $QUERY_DIR" >&2; exit 1; }
psql -X -Atc 'select 1' >/dev/null 2>&1 || { echo "ERROR: cannot connect to database $PGDATABASE. Is the server running? (bash scripts/setup_postgres.sh)" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"

mapfile -t FILES < <(ls "$QUERY_DIR"/query_*.sql 2>/dev/null | sort -V)
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no query_*.sql files in $QUERY_DIR" >&2; exit 1; }
echo ">> ${#FILES[@]} query files in $QUERY_DIR"

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
  echo "query_dir: $QUERY_DIR"
  psql -X -Atc 'select version()'
  echo "orders rows: $(psql -X -Atc 'select count(*) from orders')"
  echo "order_products rows: $(psql -X -Atc 'select count(*) from order_products')"
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

for f in "${FILES[@]}"; do
  QID="$(basename "$f" .sql)"; QID="${QID#query_}"
  want "$QID" || continue
  SQL="$(tr -d '\r' < "$f")"
  if [ "$RESTART_BETWEEN" = "1" ]; then
    pg_down >/dev/null 2>&1
    pg_up >/dev/null 2>&1 || { echo "ERROR: restart failed" >&2; exit 1; }
  fi
  for RUN in $(seq 1 "$RUNS"); do
    time_query "$SQL"
    echo "$MODE,$QID,$RUN,$MS,$STATUS,$NODE,$(date -u +%FT%TZ)" >> "$OUT"
    printf 'Q%-2s run %s: %s ms [%s]\n' "$QID" "$RUN" "${MS:-NA}" "$STATUS"
    [ "$STATUS" = "ok" ] || break   # don't repeat a failing/timeout query
  done
done

echo ">> Done. Results: $OUT"
if [ -s "$ERRLOG" ]; then echo ">> Some queries failed, see $ERRLOG"; fi