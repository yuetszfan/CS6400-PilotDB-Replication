-- Sanity checks for what the TAQA rewriter depends on. Run: psql -f scripts/checks.sql
\timing on
SELECT count(*) AS total_rows FROM hits;
SELECT relpages AS blocks, reltuples::bigint AS est_rows FROM pg_class WHERE relname = 'hits';
SELECT count(*) AS sampled_1pct FROM hits TABLESAMPLE SYSTEM (1);
SELECT count(*) AS sampled_1pct_again FROM hits TABLESAMPLE SYSTEM (1);
SELECT (ctid::text::point)[0]::int AS block_id, count(*) AS rows_in_block FROM hits GROUP BY 1 ORDER BY 1 LIMIT 5;
SELECT count(DISTINCT (ctid::text::point)[0]::int) AS distinct_blocks FROM hits;
