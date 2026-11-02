# PostgreSQL 16 + ClickBench scripts (PACE ICE)

Scripts to run PostgreSQL 16 on a PACE ICE compute node, load ClickBench `hits`, and time the exact
(unmodified) queries. Everything lives under `~/scratch` (home is only 15 GB; scratch is 300 GB and is wiped after the semester).

| File | What it does |
|---|---|
| `env.sh` | Shared settings (paths, DB name, server options). Sourced by the others; never run it directly. |
| `setup_postgres.sh` | Creates the `pg16` conda env (first time), runs `initdb` (first time), starts Postgres, creates the `clickbench` database. |
| `load_clickbench.sh` | Downloads and loads `hits`, then `VACUUM ANALYZE` and a row-count check. |
| `checks.sql` | Sanity checks that block sampling works (`TABLESAMPLE SYSTEM`, `ctid` block ids, `relpages`/`reltuples`). |
| `serve.sbatch` | Batch job that starts Postgres (and optionally loads data), then keeps it up until the time limit. |
| `run_baseline.sh` | Times ClickBench queries on exact Postgres; writes a CSV. |
| `baseline.sbatch` | Batch job: start Postgres, run `run_baseline.sh`, stop Postgres. |

## 0. One-time setup

```bash
cd ~/scratch
git clone <team repo SSH url> PilotDB      # or git pull if you already have it
cd PilotDB
mkdir -p logs
```
Use the SSH URL (`git@github.com:...`); HTTPS pushes fail on PACE because there is no display for a password prompt.

## 1. Get a compute node (never run Postgres on a login node)

```bash
salloc --nodes=1 --ntasks-per-node=8 --time=1:00:00 --qos=coc-ice
```
Change `--qos` to your class QoS (`coc-ice` or `pace-ice`). Keep `--ntasks-per-node` and `--mem` the same for
every timed run, since query times depend on the node and its resources.

## 2. Start PostgreSQL

```bash
bash scripts/setup_postgres.sh
```
Prints the PostgreSQL version when ready. Messages like `CondaError: Run 'conda init' before 'conda deactivate'` are harmless.

Connect from the same node:
```bash
source scripts/env.sh
psql                    # connects through a Unix socket; PGHOST and PGDATABASE are set by env.sh
```
Postgres listens only on a Unix socket (`$SCRATCH_DIR/pgsock`), not on the network. Any libpq client (e.g. `psycopg2`)
works with the same `PGHOST`/`PGDATABASE` environment variables, from a shell on the node that runs the server.

## 3. Load ClickBench

```bash
bash scripts/load_clickbench.sh            # 1M rows (default; for testing, ~1 GB)
ROWS=0 bash scripts/load_clickbench.sh     # full dataset (~100M rows, ~70 GB, takes a long time)
psql -f scripts/checks.sql                 # optional sanity checks
```
Run `pace-quota` before a full load. Use a batch job for long loads: `LOAD=1 ROWS=0 sbatch --time=<max> scripts/serve.sbatch`.

## 4. Run the exact baseline

```bash
bash scripts/run_baseline.sh                       # the paper's 7 queries (ids 1 2 3 4 8 21 30), 10 runs each
QUERIES=all RUNS=3 bash scripts/run_baseline.sh    # all 43 queries
QUERIES="1 21" RUNS=5 bash scripts/run_baseline.sh # any subset; ids are line numbers in the query file
RESTART_BETWEEN=1 bash scripts/run_baseline.sh     # restart Postgres before each query
```
Or as a batch job (starts and stops Postgres itself):
```bash
sbatch scripts/baseline.sbatch
sbatch --time=06:00:00 scripts/baseline.sbatch     # longer limit for the full dataset
```

Options (environment variables): `QUERY_FILE`, `RUNS`, `QUERIES`, `RESTART_BETWEEN`, `STATEMENT_TIMEOUT` (ms, 0 = none), `RESULTS_DIR`, `TAG`.

Output, in `results/`:
- `baseline_<TAG>.csv`: columns `mode,query_id,run,time_ms,status,node,utc_time`. Appended after every run, so a killed job still leaves data. `status` is `ok`, `error` or `no_timing`.
- `baseline_<TAG>_env.txt`: node, memory, Postgres settings and row count. Keep it with the CSV; the report needs it.
- `baseline_<TAG>_errors.log`: only if a query failed.

## 5. Stop cleanly

```bash
source scripts/env.sh; pg_down
exit            # release the salloc node
```
Always stop Postgres before your allocation ends or before PACE maintenance.

## Troubleshooting

- **`postmaster.pid exists but no server is running on this node`**: a previous session ended without stopping Postgres.
  Check `squeue -u $USER`. If no other job of yours could be running the server, use `FORCE_START=1 bash scripts/setup_postgres.sh`.
  Never force-start while a server may still be running on another node; two servers on one data directory can corrupt it.
- **`looks like a login node`**: get a compute node with `salloc` first.
- **`cannot connect`** when running the baseline: start the server with `setup_postgres.sh` first.
- **`results/` is git-ignored**: this repo is a clone of the authors' repo, whose `.gitignore` ignores `results`. Our `.gitignore` re-includes it with `!/results/`.
- **Only one person should run the server on the shared data directory at a time.** Each teammate normally has their own `~/scratch`.

## Caveats

- **Cache state:** the authors drop the OS page cache with root before every run. We have no root on PACE, so `RESTART_BETWEEN=1` only clears Postgres's `shared_buffers`. Treat run 1 as cold-ish and runs 2+ as warm.
- **Query ids:** the paper's 7 queries come from the authors' script `experiments/query_speedups/run_pilotdb_clickhouse.sh`. We assume the ids are 1-based, matching line numbers in `queries.sql`. This has not been confirmed in the authors' `evaluate.py`.
- **Data scale:** the loaded size must be stated in the report (default here is 1M rows, `ROWS=0` is the full ~100M). Larger scale factors may not fit in the 300 GB scratch quota.
- Times are measured by psql's `\timing` (client-side, includes returning the result).
