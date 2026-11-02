#!/bin/bash
# Load ClickBench's `hits` table into the running PostgreSQL server.
# Streams the data straight into COPY, so no multi-GB .tsv is stored on disk.
#
#   ROWS=1000000 bash scripts/load_clickbench.sh   # 1M-row test load (default)
#   ROWS=0       bash scripts/load_clickbench.sh   # full dataset (about 100M rows)
#
# Re-running DROPS and reloads the table.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
activate_pg

if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL is not running on this node. Run scripts/setup_postgres.sh first." >&2
  exit 1
fi

if [ ! -f "$CLICKBENCH_DIR/postgresql/create.sql" ]; then
  echo ">> Cloning ClickBench into $CLICKBENCH_DIR"
  git clone --depth 1 https://github.com/ClickHouse/ClickBench.git "$CLICKBENCH_DIR"
fi

if [ "$ROWS" = "0" ]; then
  echo ">> FULL load. Check first that scratch has room (run: pace-quota). Needs well over 100 GB for the table plus WAL."
else
  echo ">> Loading the first $ROWS rows"
fi

echo ">> (Re)creating table hits"
psql -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS hits"
psql -v ON_ERROR_STOP=1 -f "$CLICKBENCH_DIR/postgresql/create.sql"

echo ">> Streaming data into COPY"
START=$(date +%s)
# `head` closes the pipe early, so gunzip/curl get SIGPIPE; that is expected.
# Turn pipefail off for this one pipeline and verify with a row count instead.
set +o pipefail
if [ "$ROWS" = "0" ]; then
  curl -sSf "$HITS_URL" | gunzip | psql -v ON_ERROR_STOP=1 -c "\copy hits FROM STDIN"
else
  curl -sSf "$HITS_URL" | gunzip | head -n "$ROWS" | psql -v ON_ERROR_STOP=1 -c "\copy hits FROM STDIN"
fi
set -o pipefail
echo ">> Load took $(( $(date +%s) - START )) s"

echo ">> VACUUM ANALYZE (TAQA needs fresh statistics)"
psql -v ON_ERROR_STOP=1 -c "VACUUM ANALYZE hits"

COUNT=$(psql -Atc "SELECT count(*) FROM hits")
echo ">> hits has $COUNT rows"
if [ "$ROWS" != "0" ] && [ "$COUNT" != "$ROWS" ]; then
  echo "WARNING: expected $ROWS rows. The download may have failed; rerun this script." >&2
  exit 1
fi
if [ "$ROWS" = "0" ] && [ "$COUNT" -lt 99000000 ]; then
  echo "WARNING: full ClickBench should have about 99,997,497 rows. The load looks incomplete." >&2
  exit 1
fi
psql -c "SELECT pg_size_pretty(pg_total_relation_size('hits')) AS total_size, relpages, reltuples::bigint FROM pg_class WHERE relname = 'hits'"
