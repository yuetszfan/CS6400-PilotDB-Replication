#!/bin/bash
# Load the Instacart tables into the running PostgreSQL server (database: instacart).
#
#   INSTACART_CSV_DIR=$HOME/scratch/instacart bash scripts/load_instacart.sh
#
# Expects these Kaggle CSVs in INSTACART_CSV_DIR:
#   orders.csv  products.csv  aisles.csv  departments.csv
#   order_products__prior.csv  order_products__train.csv
# Both order_products files are loaded into ONE table `order_products`,
# matching the authors' schema. Re-running DROPS and reloads all tables.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
export PGDATABASE="${INSTACART_DB:-instacart}"   # override env.sh's clickbench default
CSV_DIR="${INSTACART_CSV_DIR:-$SCRATCH_DIR/instacart}"
activate_pg

if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL is not running on this node. Run scripts/setup_postgres.sh first." >&2
  exit 1
fi

for f in orders products aisles departments order_products__prior order_products__train; do
  [ -f "$CSV_DIR/$f.csv" ] || { echo "ERROR: missing $CSV_DIR/$f.csv" >&2; exit 1; }
done

if ! psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1; then
  echo ">> Creating database $PGDATABASE"
  createdb "$PGDATABASE"
fi

echo ">> (Re)creating tables"
psql -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS order_products, orders, products, aisles, departments;

CREATE TABLE aisles (
  aisle_id   integer,
  aisle      text
);
CREATE TABLE departments (
  department_id integer,
  department    text
);
CREATE TABLE products (
  product_id    integer,
  product_name  text,
  aisle_id      integer,
  department_id integer
);
CREATE TABLE orders (
  order_id               integer,
  user_id                integer,
  eval_set               text,
  order_number           integer,
  order_dow              integer,
  order_hour_of_day      integer,
  days_since_prior_order real
);
-- NOTE: spelling follows the authors' schema (add_to_cat_order).
CREATE TABLE order_products (
  order_id         integer,
  product_id       integer,
  add_to_cat_order integer,
  reordered        integer
);
SQL

START=$(date +%s)
echo ">> Loading CSVs"
psql -v ON_ERROR_STOP=1 -c "\copy aisles FROM '$CSV_DIR/aisles.csv' CSV HEADER"
psql -v ON_ERROR_STOP=1 -c "\copy departments FROM '$CSV_DIR/departments.csv' CSV HEADER"
psql -v ON_ERROR_STOP=1 -c "\copy products FROM '$CSV_DIR/products.csv' CSV HEADER"
psql -v ON_ERROR_STOP=1 -c "\copy orders FROM '$CSV_DIR/orders.csv' CSV HEADER"
psql -v ON_ERROR_STOP=1 -c "\copy order_products FROM '$CSV_DIR/order_products__prior.csv' CSV HEADER"
psql -v ON_ERROR_STOP=1 -c "\copy order_products FROM '$CSV_DIR/order_products__train.csv' CSV HEADER"
echo ">> Load took $(( $(date +%s) - START )) s"

echo ">> VACUUM ANALYZE (TAQA needs fresh statistics)"
psql -v ON_ERROR_STOP=1 -c "VACUUM ANALYZE"

echo ">> Row counts"
check() {  # $1 = table, $2 = expected unscaled rows
  local n; n=$(psql -Atc "SELECT count(*) FROM $1")
  printf '%-16s %12s (expected %s)\n' "$1" "$n" "$2"
  [ "$n" = "$2" ] || echo "WARNING: $1 row count differs from the unscaled Kaggle data." >&2
}
check orders 3421083
check order_products 33819106
check products 49688
check aisles 134
check departments 21

psql -c "SELECT relname, relpages AS blocks, reltuples::bigint AS est_rows FROM pg_class WHERE relname IN ('orders','order_products')"