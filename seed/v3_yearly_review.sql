-- ==========================================================
-- v3 yearly review dashboard seed (report-hub)
--
-- Seeds the `yearly` dashboard into the `reports` database:
-- full-year finance review for any calendar year present in
-- finance.transactions (2021+ as of seed time).
--
-- Drill-downs (v3.1): the "Category mix" pie and the "Category summary"
-- table link to the `categories` dashboard (category + year preserved;
-- the pie's "Other" slice is excluded); the "Spend by year" bars switch
-- the year picker in place. The per-year transactions table was removed
-- in favor of the drill-down chain (yearly -> categories -> transactions).
--
-- IDEMPOTENT: delete-then-insert per dashboard slug; safe to re-run.
-- Apply manually as dh_reports (NOT via the migration runner):
--   mysql -h thor.local -u dh_reports -p reports < seed/v3_yearly_review.sql
--
-- Conventions
--   * Same money/spend conventions as the v1 seed (see
--     v1_finance_dashboards.sql header): cents in SQL, dollars in
--     charts; spend = SUM of negative (debit) amounts, EXCLUDING
--     the Transfer and Income buckets.
--   * ?year= : cards declare config.params {year: {default,
--     allowed_query}}; the request value is validated against the
--     distinct years present in finance.transactions (returned as
--     CHAR so the string param machinery matches) and falls back
--     to the default when absent or invalid. Default = latest year
--     in the data as of seed time (2026, partial). Re-run this seed
--     to refresh the default when a new year lands.
--   * Prior-year arithmetic: :year is substituted as a quoted
--     string; MySQL coerces it in arithmetic (:year - 1) and in
--     comparisons (YEAR(...) = :year).
--   * The latest year is partial: monthly cards show the YTD shape
--     (months after the data = 0), which is the honest view.
-- ============================================================

-- 1) previous seed state (cards cascade from dashboards)
DELETE FROM dashboards WHERE slug IN ('yearly');
DELETE FROM queries WHERE name IN ('fin_year_spend', 'fin_year_spend_yoy', 'fin_year_txn_count', 'fin_year_monthly_spend', 'fin_year_category_mix', 'fin_year_spend_by_year', 'fin_year_category_summary', 'fin_year_top_payees', 'fin_year_monthly_totals', 'fin_year_txns', 'fin_year_spend_forecast');

-- 2) saved queries (table cards reference these; charts/labels also
--    inline the SQL in config, v1 pattern — saved rows are provenance)

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_spend', 'SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE YEAR(t.txn_date) = :year', '{"year": "2026"}', 'Spend (cents) in calendar year :year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_spend_yoy', 'SELECT (COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
       / NULLIF(COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year - 1 AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE YEAR(t.txn_date) BETWEEN :year - 1 AND :year', '{"year": "2026"}', 'YoY fractional spend change in :year vs prior calendar year (NULL when prior year has no data)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_txn_count', 'SELECT COUNT(*)
FROM transactions t
WHERE YEAR(t.txn_date) = :year', '{"year": "2026"}', 'Transaction count in calendar year :year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_monthly_spend', 'WITH RECURSIVE months AS (
  SELECT STR_TO_DATE(CONCAT(:year, ''-01-01''), ''%Y-%m-%d'') mstart, 1 n
  UNION ALL
  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1
  FROM months
  WHERE n < 12
)
SELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym,
       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend
FROM months mo
LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
LEFT JOIN categories c ON c.id = t.category_id
GROUP BY mo.mstart
ORDER BY mo.mstart', '{"year": "2026"}', 'Monthly spend (dollars) in calendar year :year, Jan-Dec spine (months after the data = 0)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_category_mix', 'WITH base AS (
  SELECT c.name,
         COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) cents
  FROM transactions t
  JOIN categories c ON c.id = t.category_id
  WHERE c.bucket NOT IN (''Transfer'', ''Income'')
    AND YEAR(t.txn_date) = :year
  GROUP BY c.name
),
top AS (SELECT name, cents FROM base ORDER BY cents DESC LIMIT 10)
SELECT name, ROUND(cents / 100, 2) spend FROM top
UNION ALL
SELECT ''Other'', ROUND(COALESCE(SUM(cents), 0) / 100, 2) FROM base
WHERE name NOT IN (SELECT name FROM top)', '{"year": "2026"}', 'Spend (dollars) by leaf category in :year: top 10 + Other (pie)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_spend_by_year', 'SELECT CAST(YEAR(t.txn_date) AS CHAR) y,
       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend
FROM transactions t
JOIN categories c ON c.id = t.category_id
GROUP BY y
ORDER BY y', NULL, 'Spend (dollars) by calendar year, all data (latest year partial)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_category_summary', 'SELECT c.name category,
       c.bucket,
       COUNT(*) txn_count,
       COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) spend_cents,
       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0)
             / NULLIF((SELECT COALESCE(SUM(CASE WHEN t2.amount_cents < 0 THEN -t2.amount_cents END), 0)
                       FROM transactions t2
                       JOIN categories c2 ON c2.id = t2.category_id
                       WHERE c2.bucket NOT IN (''Transfer'', ''Income'')
                         AND YEAR(t2.txn_date) = :year), 0) * 100, 1) share_pct
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE c.bucket NOT IN (''Transfer'', ''Income'')
  AND YEAR(t.txn_date) = :year
GROUP BY c.name, c.bucket
ORDER BY spend_cents DESC', '{"year": "2026"}', 'Spend by leaf category in :year (cents, txn count, share of year spend)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_top_payees', 'SELECT t.payee,
       c.name category,
       COUNT(*) txn_count,
       COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) total_cents,
       MAX(t.txn_date) last_seen
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.amount_cents < 0
  AND YEAR(t.txn_date) = :year
GROUP BY t.payee, c.name
ORDER BY total_cents DESC', '{"year": "2026"}', 'Top payees in calendar year :year (spend only)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_monthly_totals', 'SELECT DATE_FORMAT(t.txn_date, ''%Y-%m'') ym,
       COUNT(*) txn_count,
       COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) spend_cents,
       ROUND(COALESCE(AVG(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) avg_txn
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE YEAR(t.txn_date) = :year
GROUP BY DATE_FORMAT(t.txn_date, ''%Y-%m'')
ORDER BY ym', '{"year": "2026"}', 'Monthly totals in :year: txn count, spend (cents), avg txn (dollars)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_year_spend_forecast', 'WITH monthly AS (\n  SELECT m.n mo, COALESCE(s.cents, 0) cents\n  FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12) m\n  LEFT JOIN (\n    SELECT MONTH(t.txn_date) mo,\n           SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'',''Income'') THEN -t.amount_cents END) cents\n    FROM transactions t\n    JOIN categories c ON c.id = t.category_id\n    WHERE YEAR(t.txn_date) = :year\n    GROUP BY MONTH(txn_date)\n  ) s ON s.mo = m.n\n),\nle AS (SELECT COALESCE(MAX(mo), 0) le FROM monthly WHERE cents > 0),\nfit AS (\n  SELECT MAX(l.le) n, SUM(m.mo) sx, SUM(m.mo*m.mo) sx2, SUM(m.cents) sy, SUM(m.mo*m.cents) sxy\n  FROM monthly m CROSS JOIN le l\n  WHERE m.mo <= l.le\n)\nSELECT CASE\n  WHEN n IS NULL OR n = 0 THEN 0\n  WHEN :year < YEAR(CURDATE()) THEN (SELECT COALESCE(SUM(cents), 0) FROM monthly)\n  WHEN n = 1 THEN sy * 12\n  ELSE (12.0*sy)/n + ((n*sxy - sx*sy)/NULLIF(n*sx2 - sx*sx, 0)) * (78 - 12.0*sx/n)\nEND\nFROM fit', '{"year": "2026"}', 'Full-year spend in :year: actual for prior years; for the current (partial) year, a linear-trend (OLS on monthly spend) forecast of the full year, so full years are compared. Cents.');

-- 3) dashboard + cards

INSERT INTO dashboards (slug, title, description, layout, section, sort_order, is_active) VALUES ('yearly', 'Yearly Review', 'Pick a year (or ?year=2024). Full-year spend with YoY (full-year basis: partial current year compared on a linear-trend forecast), monthly spend, category mix, payees. Click a category slice/row to open Categories; bars switch years.', '{"param_nav": [{"param": "year", "label": "Year", "all_label": "Latest year (default)", "query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}]}', 'finance', 30, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 1, 'label', 'Spend in :year', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE YEAR(t.txn_date) = :year", "format": "currency", "delta_query": "WITH monthly AS (\\n  SELECT m.n mo, COALESCE(s.cents, 0) cents\\n  FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12) m\\n  LEFT JOIN (\\n    SELECT MONTH(t.txn_date) mo,\\n           SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'',''Income'') THEN -t.amount_cents END) cents\\n    FROM transactions t\\n    JOIN categories c ON c.id = t.category_id\\n    WHERE YEAR(t.txn_date) = :year\\n    GROUP BY MONTH(txn_date)\\n  ) s ON s.mo = m.n\\n),\\nle AS (SELECT COALESCE(MAX(mo), 0) le FROM monthly WHERE cents > 0),\\nfit AS (\\n  SELECT MAX(l.le) n, SUM(m.mo) sx, SUM(m.mo*m.mo) sx2, SUM(m.cents) sy, SUM(m.mo*m.cents) sxy\\n  FROM monthly m CROSS JOIN le l\\n  WHERE m.mo <= l.le\\n)\\nSELECT CASE\\n  WHEN n IS NULL OR n = 0 THEN NULL\\n  WHEN :year < YEAR(CURDATE()) THEN (SELECT COALESCE(SUM(cents), 0) FROM monthly)\\n  WHEN n = 1 THEN sy * 12\\n  ELSE (12.0*sy)/n + ((n*sxy - sx*sy)/NULLIF(n*sx2 - sx*sx, 0)) * (78 - 12.0*sx/n)\\nEND / NULLIF(\\n  (SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'',''Income'') THEN -t.amount_cents END), 0)\\n   FROM transactions t JOIN categories c ON c.id = t.category_id\\n   WHERE YEAR(t.txn_date) = :year - 1), 0) - 1\\nFROM fit", "delta_format": "percent", "delta_label": "YoY (full-year basis)", "delta_good": "down", "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 2, 'label', 'Full-year spend in :year (forecast if partial)', NULL, '{"level": 2, "value_query": "WITH monthly AS (\\n  SELECT m.n mo, COALESCE(s.cents, 0) cents\\n  FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12) m\\n  LEFT JOIN (\\n    SELECT MONTH(t.txn_date) mo,\\n           SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'',''Income'') THEN -t.amount_cents END) cents\\n    FROM transactions t\\n    JOIN categories c ON c.id = t.category_id\\n    WHERE YEAR(t.txn_date) = :year\\n    GROUP BY MONTH(txn_date)\\n  ) s ON s.mo = m.n\\n),\\nle AS (SELECT COALESCE(MAX(mo), 0) le FROM monthly WHERE cents > 0),\\nfit AS (\\n  SELECT MAX(l.le) n, SUM(m.mo) sx, SUM(m.mo*m.mo) sx2, SUM(m.cents) sy, SUM(m.mo*m.cents) sxy\\n  FROM monthly m CROSS JOIN le l\\n  WHERE m.mo <= l.le\\n)\\nSELECT CASE\\n  WHEN n IS NULL OR n = 0 THEN 0\\n  WHEN :year < YEAR(CURDATE()) THEN (SELECT COALESCE(SUM(cents), 0) FROM monthly)\\n  WHEN n = 1 THEN sy * 12\\n  ELSE (12.0*sy)/n + ((n*sxy - sx*sy)/NULLIF(n*sx2 - sx*sx, 0)) * (78 - 12.0*sx/n)\\nEND\\nFROM fit", "format": "currency", "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 3, 'label', 'Full-year basis', NULL, '{"level": 4, "text": "Full-year basis: for the current (partial) year, the Spend figure is year-to-date and the YoY delta compares a linear-trend full-year forecast to the prior year, so full years are compared. For prior years, figures are actuals."}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 4, 'label', 'Transactions in :year', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM transactions t\\nWHERE YEAR(t.txn_date) = :year", "format": "number", "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 5, 'chart', 'Monthly spend in :year', (SELECT id FROM queries WHERE name = 'fin_year_monthly_spend'), '{"data_query": "WITH RECURSIVE months AS (\\n  SELECT STR_TO_DATE(CONCAT(:year, ''-01-01''), ''%Y-%m-%d'') mstart, 1 n\\n  UNION ALL\\n  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1\\n  FROM months\\n  WHERE n < 12\\n)\\nSELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym,\\n       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend\\nFROM months mo\\nLEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\nLEFT JOIN categories c ON c.id = t.category_id\\nGROUP BY mo.mstart\\nORDER BY mo.mstart", "data_map": {"x": "ym", "value": "spend"}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 70, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Spend", "type": "bar", "itemStyle": {"color": "#4f8ef7"}, "data": []}]}, "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 6, 'chart', 'Category mix in :year (click a slice to drill in)', (SELECT id FROM queries WHERE name = 'fin_year_category_mix'), '{"data_query": "WITH base AS (\\n  SELECT c.name,\\n         COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) cents\\n  FROM transactions t\\n  JOIN categories c ON c.id = t.category_id\\n  WHERE c.bucket NOT IN (''Transfer'', ''Income'')\\n    AND YEAR(t.txn_date) = :year\\n  GROUP BY c.name\\n),\\ntop AS (SELECT name, cents FROM base ORDER BY cents DESC LIMIT 10)\\nSELECT name, ROUND(cents / 100, 2) spend FROM top\\nUNION ALL\\nSELECT ''Other'', ROUND(COALESCE(SUM(cents), 0) / 100, 2) FROM base\\nWHERE name NOT IN (SELECT name FROM top)", "data_map": {"x": "name", "value": "spend"}, "link": {"dashboard": "categories", "params": {"category": "{x}", "year": ":year"}, "exclude": ["Other"]}, "option": {"tooltip": {"trigger": "item", "formatter": "{b}: ${c} ({d}%)"}, "series": [{"name": "Spend", "type": "pie", "radius": ["35%", "65%"], "label": {"formatter": "{b}\\n${c}"}, "itemStyle": {"cursor": "pointer"}, "data": []}]}, "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 7, 'chart', 'Spend by year (all data)', (SELECT id FROM queries WHERE name = 'fin_year_spend_by_year'), '{"data_query": "SELECT CAST(YEAR(t.txn_date) AS CHAR) y,\\n       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nGROUP BY y\\nORDER BY y", "data_map": {"x": "y", "value": "spend"}, "link": {"params": {"year": "{x}"}}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 70, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category"}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Spend", "type": "bar", "itemStyle": {"color": "#37b28c", "cursor": "pointer"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 8, 'table', 'Category summary in :year (click a category to drill in)', (SELECT id FROM queries WHERE name = 'fin_year_category_summary'), '{"formats": {"spend_cents": "currency", "txn_count": "number", "share_pct": "number"}, "page_size": 250, "links": {"category": {"dashboard": "categories", "params": {"category": "{category}", "year": ":year"}}}, "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 9, 'table', 'Top payees in :year', (SELECT id FROM queries WHERE name = 'fin_year_top_payees'), '{"formats": {"total_cents": "currency", "txn_count": "number", "last_seen": "date"}, "page_size": 250, "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}'),
  ((SELECT id FROM dashboards WHERE slug = 'yearly'), 10, 'table', 'Monthly totals in :year', (SELECT id FROM queries WHERE name = 'fin_year_monthly_totals'), '{"formats": {"spend_cents": "currency", "txn_count": "number", "avg_txn": "currency"}, "page_size": 250, "params": {"year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}');
