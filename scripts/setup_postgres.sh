#!/bin/bash
# Create (if needed) the pg16 conda env, initialize the data directory (if needed),
# start PostgreSQL 16 and create the database.
#
# Run on a COMPUTE node, never the login node:
#   salloc --nodes=1 --ntasks-per-node=8 --time=1:00:00 --qos=<your class QoS>
#   bash scripts/setup_postgres.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

case "$(hostname)" in
  login*) echo "ERROR: this looks like a login node ($(hostname)). Get a compute node with salloc first." >&2; exit 1 ;;
esac

if type module >/dev/null 2>&1; then module load anaconda3; fi
command -v conda >/dev/null 2>&1 || { echo "ERROR: conda not found. Run 'module load anaconda3' first." >&2; exit 1; }

if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
  echo ">> Creating conda env $CONDA_ENV (PostgreSQL 16)"
  conda create -y -n "$CONDA_ENV" -c conda-forge postgresql=16
fi
activate_pg
postgres --version

mkdir -p "$SCRATCH_DIR" "$PGHOST"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo ">> initdb in $PGDATA"
  initdb -D "$PGDATA"
fi

pg_up

if ! psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1; then
  createdb "$PGDATABASE"
fi

psql -Atc "select version();"
echo ">> Ready. Connect with: psql   (PGHOST=$PGHOST PGDATABASE=$PGDATABASE)"
echo ">> Stop cleanly with:   pg_ctl -D $PGDATA stop"
