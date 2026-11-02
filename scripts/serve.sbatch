#!/bin/bash
#SBATCH --job-name=pg16-clickbench
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --qos=coc-ice
#SBATCH --output=logs/serve_%j.out
#SBATCH --signal=B:TERM@120
#
# Starts PostgreSQL 16, optionally loads ClickBench, then keeps the server up until the
# time limit (or `scancel`), and shuts it down cleanly.
#
#   mkdir -p logs
#   sbatch scripts/serve.sbatch                        # start the server only
#   LOAD=1 ROWS=1000000 sbatch scripts/serve.sbatch    # also (re)load 1M rows
#   LOAD=1 ROWS=0 sbatch --time=08:00:00 scripts/serve.sbatch   # full load, then serve
#
# Change --qos above to your class's QoS (coc-ice or pace-ice).
# Cleanup on SIGTERM only works because of --signal=B:TERM@120: Slurm warns the batch
# shell 120 s before the time limit.
set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Slurm runs a copy of this script from a spool dir, so locate scripts via the submit dir.
[ -f "$SCRIPT_DIR/env.sh" ] || SCRIPT_DIR="${SLURM_SUBMIT_DIR:-.}/scripts"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

bash "$SCRIPT_DIR/setup_postgres.sh" || { echo "setup failed"; exit 1; }
activate_pg

if [ "${LOAD:-0}" = "1" ]; then
  bash "$SCRIPT_DIR/load_clickbench.sh" || echo "WARNING: load did not finish cleanly"
fi

hostname > "$SCRATCH_DIR/pg_host.txt"
echo "Server up on $(hostname), socket dir $PGHOST. Job $SLURM_JOB_ID. Waiting."

cleanup() {
  echo "Stopping PostgreSQL cleanly"
  pg_down
  exit 0
}
trap cleanup TERM INT

# `sleep` in the background + `wait` lets the trap run immediately when a signal arrives.
while true; do
  sleep 60 &
  wait $!
done
