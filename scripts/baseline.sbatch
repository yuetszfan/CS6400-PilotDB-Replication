#!/bin/bash
#SBATCH --job-name=pg16-baseline
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --qos=coc-ice
#SBATCH --output=logs/baseline_%j.out
#SBATCH --signal=B:TERM@120
#
# One job that starts PostgreSQL, runs the exact-query baseline, and stops PostgreSQL.
#
#   mkdir -p logs
#   sbatch scripts/baseline.sbatch
#   (default: the paper's 7 queries x 10 runs)
#   QUERIES=all RUNS=3 sbatch scripts/baseline.sbatch            # all 43 queries; options pass through
#   sbatch --time=06:00:00 scripts/baseline.sbatch               # longer, for the full dataset
#
# Change --qos to your class's QoS (coc-ice or pace-ice). Keep --ntasks-per-node and --mem the
# same for every timed run: query times depend on the node and its resources.
set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Slurm runs a copy of this script from a spool dir, so locate scripts via the submit dir.
[ -f "$SCRIPT_DIR/env.sh" ] || SCRIPT_DIR="${SLURM_SUBMIT_DIR:-.}/scripts"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

bash "$SCRIPT_DIR/setup_postgres.sh" || { echo "setup failed"; exit 1; }
activate_pg || exit 1

BASEPID=""
cleanup() {
  echo "Signal received: stopping baseline and PostgreSQL"
  if [ -n "$BASEPID" ]; then kill "$BASEPID" 2>/dev/null; fi
  pg_down
  exit 0
}
trap cleanup TERM INT

bash "$SCRIPT_DIR/run_baseline.sh" &
BASEPID=$!
wait "$BASEPID"
RC=$?
echo "Baseline finished with exit code $RC"
pg_down
exit "$RC"
