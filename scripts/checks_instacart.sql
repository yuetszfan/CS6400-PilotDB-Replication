-- Sanity checks for what the TAQA rewriter depends on. Run: psql -f scripts/checks.sql
\timing on
SELECT count(*) AS total_rows FROM order_products;
SELECT relpages AS blocks, reltuples::bigint AS est_rows FROM pg_class WHERE relname = 'order_products';
SELECT count(*) AS sampled_1pct FROM order_products TABLESAMPLE SYSTEM (1);
SELECT count(*) AS sampled_1pct_again FROM order_products TABLESAMPLE SYSTEM (1);
SELECT (ctid::text::point)[0]::int AS block_id, count(*) AS rows_in_block FROM order_products GROUP BY 1 ORDER BY 1 LIMIT 5;
SELECT count(DISTINCT (ctid::text::point)[0]::int) AS distinct_blocks FROM order_products;
