-- ==========================================================
-- v3.1 transactions dashboard seed (report-hub)
--
-- Seeds the `transactions` dashboard into the `reports` database:
-- all transactions for a category (bucket or leaf) in a month.
-- Drill-down target from the Categories dashboard's monthly-spend
-- chart (and the yearly -> categories -> transactions chain).
--
-- IDEMPOTENT: delete-then-insert per dashboard slug; safe to re-run.
-- Apply manually as dh_reports (NOT via the migration runner):
--   mysql -h thor.local -u dh_reports -p reports < seed/v3_transactions.sql
--
-- Conventions
--   * Same money/spend conventions as the v1/v3 seeds (see
--     v1_finance_dashboards.sql header): cents in SQL, dollars in
--     charts; spend = SUM of negative (debit) amounts, EXCLUDING
--     the Transfer and Income buckets.
--   * ?category= / ?month= : cards declare config.params
--     {category, month: {default, allowed_query}}; the request values
--     are validated against ALL category names (buckets AND leaves,
--     matching the categories dashboard) and the distinct transaction
--     months, falling back to the defaults when absent or invalid.
--     Defaults as of seed time (2026-10): category = top-spend bucket
--     over the trailing 12 months = Food & Dining; month = latest
--     month in the data = 2026-10. Re-run this seed to refresh.
--   * Month window: :month is a 'YYYY-MM' string, substituted as an
--     escaped string literal; the window is [month start, next month
--     start). The spend delta compares against the SAME month one year
--     earlier (derived from :month in SQL via DATE_SUB).
-- ============================================================

-- 1) previous seed state (cards cascade from dashboards)
DELETE FROM dashboards WHERE slug IN ('transactions');
DELETE FROM queries WHERE name IN ('fin_txn_month_spend', 'fin_txn_month_spend_delta', 'fin_txn_month_count', 'fin_txn_month_top_payees', 'fin_txn_month_txns');

-- 2) saved queries (table cards reference these; the label cards inline
--    the SQL in config, v1/v3 pattern — saved rows are provenance)

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_month_spend', 'SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')
  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)', '{"category": "Food & Dining", "month": "2026-10"}', 'Spend (cents) in category :category (bucket or leaf) in month :month, excl. Transfer/Income');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_month_spend_delta', 'SELECT (SUM(CASE WHEN t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'') THEN -t.amount_cents ELSE 0 END)
       / NULLIF(SUM(CASE WHEN t.txn_date < STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'') THEN -t.amount_cents ELSE 0 END), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE t.amount_cents < 0
  AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND (c.bucket = :category OR c.name = :category)
  AND t.txn_date >= DATE_SUB(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 YEAR)
  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)', '{"category": "Food & Dining", "month": "2026-10"}', 'Fractional spend change in :category for :month vs the same month one year earlier (NULL when prior month has no data)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_month_count', 'SELECT COUNT(*)
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')
  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)', '{"category": "Food & Dining", "month": "2026-10"}', 'Transaction count in category :category (bucket or leaf) in month :month');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_month_top_payees', 'SELECT t.payee,
       COUNT(*) txn_count,
       COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) total_cents,
       MAX(t.txn_date) last_seen
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND t.amount_cents < 0
  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')
  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)
GROUP BY t.payee
ORDER BY total_cents DESC
LIMIT 25', '{"category": "Food & Dining", "month": "2026-10"}', 'Top payees in category :category in month :month (spend only)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_month_txns', 'SELECT t.txn_date date,
       t.payee,
       t.description,
       t.amount_cents amount,
       c.name category
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')
  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)
ORDER BY t.txn_date DESC, t.id DESC', '{"category": "Food & Dining", "month": "2026-10"}', 'All transactions in category :category in month :month (newest first)');

-- 3) dashboard + cards

INSERT INTO dashboards (slug, title, description, layout, is_active) VALUES ('transactions', 'Transactions', 'All transactions for a category in a month (or ?category=...&month=...). Drill-down target from the Categories monthly-spend chart. Pickers: category (bucket or leaf) + month. Default = top-spend category + latest month.', '{"param_nav": [{"param": "category", "label": "Category", "all_label": "Top-spend category (default)", "query": "SELECT name FROM categories WHERE parent_id = 0 ORDER BY name"}, {"param": "month", "label": "Month", "all_label": "Latest month (default)", "query": "SELECT DATE_FORMAT(txn_date, ''%Y-%m'') ym FROM transactions GROUP BY ym ORDER BY ym DESC"}]}', 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'transactions'), 1, 'label', 'Spend in :category (:month)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE (c.bucket = :category OR c.name = :category)\\n  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')\\n  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)", "format": "currency", "delta_query": "SELECT (SUM(CASE WHEN t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'') THEN -t.amount_cents ELSE 0 END)\\n       / NULLIF(SUM(CASE WHEN t.txn_date < STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'') THEN -t.amount_cents ELSE 0 END), 0)) - 1\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE t.amount_cents < 0\\n  AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND (c.bucket = :category OR c.name = :category)\\n  AND t.txn_date >= DATE_SUB(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 YEAR)\\n  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)", "delta_format": "percent", "delta_label": "vs same month prior year", "delta_good": "down", "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "month": {"default": "2026-10", "allowed_query": "SELECT DATE_FORMAT(txn_date, ''%Y-%m'') ym FROM transactions GROUP BY ym ORDER BY ym DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'transactions'), 2, 'label', 'Transactions in :category (:month)', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE (c.bucket = :category OR c.name = :category)\\n  AND t.txn_date >= STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d'')\\n  AND t.txn_date < DATE_ADD(STR_TO_DATE(CONCAT(:month, ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH)", "format": "number", "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "month": {"default": "2026-10", "allowed_query": "SELECT DATE_FORMAT(txn_date, ''%Y-%m'') ym FROM transactions GROUP BY ym ORDER BY ym DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'transactions'), 3, 'table', 'Top payees in :category (:month)', (SELECT id FROM queries WHERE name = 'fin_txn_month_top_payees'), '{"formats": {"total_cents": "currency", "txn_count": "number", "last_seen": "date"}, "page_size": 250, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "month": {"default": "2026-10", "allowed_query": "SELECT DATE_FORMAT(txn_date, ''%Y-%m'') ym FROM transactions GROUP BY ym ORDER BY ym DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'transactions'), 4, 'table', 'All transactions in :category (:month)', (SELECT id FROM queries WHERE name = 'fin_txn_month_txns'), '{"formats": {"date": "date", "amount": "currency"}, "page_size": 250, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "month": {"default": "2026-10", "allowed_query": "SELECT DATE_FORMAT(txn_date, ''%Y-%m'') ym FROM transactions GROUP BY ym ORDER BY ym DESC"}}}');

-- done: 1 dashboard, 5 queries, 4 cards
