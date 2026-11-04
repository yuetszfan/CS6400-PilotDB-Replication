#!/bin/bash
# Scale the Instacart `orders` and `order_products` tables by SCALE_FACTOR (default 50).
# products, aisles and departments are NOT scaled.
#
#   bash scripts/scale_instacart.sh                    # 50x
#   SCALE_FACTOR=10 bash scripts/scale_instacart.sh    # smaller test run
#   RESET=1 bash scripts/scale_instacart.sh            # drop leftover scale state (run load_instacart.sh first!)
#
# How it works: copy k (k = 0..F-1) re-inserts every order with
#   order_id + k*max_order_id   and   user_id + k*max_user_id
# in BOTH tables, so joins on order_id stay consistent and every copy is a fresh set of
# orders/users. product_id is unchanged. Copy 0 is the original data.
#
# Resumable: each copy is one transaction that also records itself in scale_progress, so a
# killed job can simply be rerun. Needs a running server and the unscaled tables
# (scripts/load_instacart.sh). Run it inside an allocation with a long time limit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
export PGDATABASE="${INSTACART_DB:-instacart}"
SCALE_FACTOR="${SCALE_FACTOR:-50}"
export PGOPTIONS="-c synchronous_commit=off"
activate_pg

if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL is not running on this node. Run scripts/setup_postgres.sh first." >&2
  exit 1
fi

q() { psql -X -Atq -v ON_ERROR_STOP=1 -c "$1"; }
exists() { [ "$(q "SELECT to_regclass('public.$1') IS NOT NULL")" = "t" ]; }

if [ "${RESET:-0}" = "1" ]; then
  echo ">> RESET: dropping scale state (orders/order_products are NOT touched)"
  q "DROP TABLE IF EXISTS scale_meta, scale_progress, orders_base, order_products_base"
fi

# ---- Decide: fresh start, resume, or already done ----
if ! exists scale_meta; then
  # Fresh start. Refuse to scale data that is already bigger than the unscaled dataset.
  ORD=$(q "SELECT count(*) FROM orders")
  if [ "$ORD" != "3421083" ]; then
    echo "ERROR: orders has $ORD rows, not the unscaled 3421083. Run scripts/load_instacart.sh first," >&2
    echo "       then RESET=1 bash scripts/scale_instacart.sh if old scale state is left over." >&2
    exit 1
  fi

  # Disk check: new tables will be about SCALE_FACTOR x the base size.
  BASE_BYTES=$(q "SELECT pg_total_relation_size('orders') + pg_total_relation_size('order_products')")
  AVAIL_BYTES=$(( $(df -Pk "$PGDATA" | awk 'NR==2{print $4}') * 1024 ))
  NEED_BYTES=$(( BASE_BYTES * (SCALE_FACTOR + 1) * 12 / 10 ))
  echo ">> Base size $((BASE_BYTES / 1000000000)) GB; estimated need ~$((NEED_BYTES / 1000000000)) GB; available $((AVAIL_BYTES / 1000000000)) GB"
  if [ "$NEED_BYTES" -gt "$AVAIL_BYTES" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "ERROR: probably not enough space. Lower SCALE_FACTOR (or FORCE=1 to try anyway). Check: pace-quota" >&2
    exit 1
  fi

  echo ">> Setting up: renaming originals to *_base and creating empty target tables"
  psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
ALTER TABLE orders RENAME TO orders_base;
ALTER TABLE order_products RENAME TO order_products_base;
CREATE TABLE orders (LIKE orders_base);
CREATE TABLE order_products (LIKE order_products_base);
CREATE TABLE scale_meta (factor integer);
CREATE TABLE scale_progress (copy_k integer PRIMARY KEY);
COMMIT;
SQL
  q "INSERT INTO scale_meta VALUES ($SCALE_FACTOR)"
fi

FACTOR=$(q "SELECT factor FROM scale_meta")
if [ "$FACTOR" != "$SCALE_FACTOR" ]; then
  echo ">> Resuming an earlier run with factor $FACTOR (ignoring SCALE_FACTOR=$SCALE_FACTOR)"
fi

# ---- Copy loop ----
if exists orders_base; then
  MAX_ORDER=$(q "SELECT max(order_id) FROM orders_base")
  MAX_USER=$(q "SELECT max(user_id) FROM orders_base")
  START=$(date +%s)
  for k in $(seq 0 $((FACTOR - 1))); do
    if [ "$(q "SELECT count(*) FROM scale_progress WHERE copy_k = $k")" = "1" ]; then
      continue
    fi
    psql -X -q -v ON_ERROR_STOP=1 -v k="$k" -v oo=$((k * MAX_ORDER)) -v uo=$((k * MAX_USER)) <<'SQL'
BEGIN;
INSERT INTO orders
  SELECT order_id + :oo, user_id + :uo, eval_set, order_number, order_dow,
         order_hour_of_day, days_since_prior_order
  FROM orders_base;
INSERT INTO order_products
  SELECT order_id + :oo, product_id, add_to_cat_order, reordered
  FROM order_products_base;
INSERT INTO scale_progress VALUES (:k);
COMMIT;
SQL
    echo ">> copy $((k + 1))/$FACTOR done ($(( $(date +%s) - START )) s elapsed)"
  done

  # ---- Verify, then drop the base copies ----
  EXP_ORD=$(( $(q "SELECT count(*) FROM orders_base") * FACTOR ))
  EXP_OP=$(( $(q "SELECT count(*) FROM order_products_base") * FACTOR ))
  GOT_ORD=$(q "SELECT count(*) FROM orders")
  GOT_OP=$(q "SELECT count(*) FROM order_products")
  if [ "$GOT_ORD" != "$EXP_ORD" ] || [ "$GOT_OP" != "$EXP_OP" ]; then
    echo "ERROR: row counts wrong (orders $GOT_ORD vs $EXP_ORD, order_products $GOT_OP vs $EXP_OP). Base tables kept." >&2
    exit 1
  fi
  q "DROP TABLE orders_base, order_products_base"
else
  echo ">> Already scaled (base tables are gone). Nothing to copy."
fi

echo ">> VACUUM ANALYZE (TAQA needs fresh statistics)"
psql -X -q -v ON_ERROR_STOP=1 -c "VACUUM ANALYZE orders" -c "VACUUM ANALYZE order_products"

psql -X -c "SELECT relname,
                   pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
                   relpages AS blocks,
                   reltuples::bigint AS est_rows
            FROM pg_class
            WHERE relname IN ('orders', 'order_products')"
echo ">> Scale factor: $FACTOR. Record this and the sizes above in the report."