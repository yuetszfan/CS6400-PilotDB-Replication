#!/bin/bash
# Shared settings for the PostgreSQL scripts. Source it; don't run it.
# Override any value by exporting it first, e.g.:  ROWS=0 bash scripts/load_clickbench.sh

export SCRATCH_DIR="${SCRATCH_DIR:-$HOME/scratch}"
export CONDA_ENV="${CONDA_ENV:-pg16}"

# Server layout (all on scratch; home is only 15 GB)
export PGDATA="${PGDATA:-$SCRATCH_DIR/pgdata}"
export PG_LOG="${PG_LOG:-$SCRATCH_DIR/pg.log}"

# Team connection convention: a directory in PGHOST means "Unix socket".
# With these set, plain `psql` works, and so does any libpq-based client (e.g. psycopg2).
export PGHOST="${PGHOST:-$SCRATCH_DIR/pgsock}"
export PGDATABASE="${PGDATABASE:-clickbench}"

# ClickBench
export CLICKBENCH_DIR="${CLICKBENCH_DIR:-$SCRATCH_DIR/ClickBench}"
export DATA_DIR="${DATA_DIR:-$SCRATCH_DIR/data}"
export HITS_URL="${HITS_URL:-https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz}"
export ROWS="${ROWS:-1000000}"   # 0 = the full dataset

# Server settings. Record whatever you actually use in the report (environment differences).
SHARED_BUFFERS="${SHARED_BUFFERS:-2GB}"
MAX_WAL_SIZE="${MAX_WAL_SIZE:-16GB}"
MAINTENANCE_MEM="${MAINTENANCE_MEM:-1GB}"
export PG_OPTS="-c listen_addresses='' -k $PGHOST -c shared_buffers=$SHARED_BUFFERS -c max_wal_size=$MAX_WAL_SIZE -c maintenance_work_mem=$MAINTENANCE_MEM"

activate_pg() {
  # conda's activate scripts reference unset variables, so `set -u` must be off around them.
  local had_u=0
  case "$-" in *u*) had_u=1; set +u ;; esac
  if type module >/dev/null 2>&1; then module load anaconda3; fi
  if ! command -v conda >/dev/null 2>&1; then
    echo "ERROR: conda not found. Run 'module load anaconda3' in your shell, then retry." >&2
    [ "$had_u" = 1 ] && set -u
    return 1
  fi
  eval "$(conda shell.bash hook)"
  conda activate "$CONDA_ENV"
  [ "$had_u" = 1 ] && set -u
  return 0
}

pg_up() {
  mkdir -p "$PGHOST"
  if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    echo "PostgreSQL already running on $(hostname)"
    return 0
  fi
  if [ -f "$PGDATA/postmaster.pid" ]; then
    if [ "${FORCE_START:-0}" != "1" ]; then
      echo "ERROR: $PGDATA/postmaster.pid exists but no server is running on this node."
      echo "  - If a server is still running on another node (check: squeue -u $USER), stop it there first."
      echo "    Two servers on one data directory can corrupt it."
      echo "  - If a previous job was killed, rerun with FORCE_START=1."
      return 1
    fi
    rm -f "$PGDATA/postmaster.pid"
  fi
  pg_ctl -D "$PGDATA" -o "$PG_OPTS" -l "$PG_LOG" -w start
}

pg_down() {
  pg_ctl -D "$PGDATA" -m fast -w stop || true
}
