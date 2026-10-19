-- ==========================================================
-- v1 finance dashboards seed (report-hub)
--
-- Seeds the 5 v1 finance dashboards into the `reports` database:
--   overview, categories, kids, tax-savings, data-health
-- plus their saved queries (reports.queries) and cards (reports.cards).
--
-- IDEMPOTENT: delete-then-insert per dashboard slug; safe to re-run.
-- Apply manually as dh_reports (NOT via the migration runner):
--   mysql -h thor.local -u dh_reports -p reports < seed/v1_finance_dashboards.sql
--
-- Conventions
--   * Money = integer cents in finance; tables present cents via the
--     "currency" card format. Chart values are dollars (divided by 100
--     in SQL) so ECharts axes stay readable.
--   * Spend = SUM of negative (debit) amounts, presented as positive.
--     "Spend" everywhere EXCLUDES the Transfer and Income buckets:
--     transfers move money between accounts (not consumption) and
--     income is credits. "Deposits" = positive amounts in the Income
--     bucket.
--   * "Last / trailing 12 months" = the 12 months ending at the latest
--     (year, month) present in finance.monthly_category_summary,
--     derived in SQL (no hardcoded dates). "24mo" = the 24 months
--     ending there.
--   * ?category= / ?year= : the `categories` dashboard is year-scoped
--     with two pickers (category + year). Cards declare
--     config.params {category, year: {default, allowed_query}}; the
--     request values are validated against ALL category names (buckets
--     AND leaves, so drill-downs from the yearly dashboard's leaf rows
--     work) and the distinct transaction years, falling back to the
--     defaults when absent or invalid. Defaults as of seed time
--     (2026-10): category = top-spend bucket over the trailing 12
--     months = Food & Dining; year = latest year in the data = 2026.
--     Re-run this seed to refresh the defaults.
--
-- KID DEFINITION (v1)
--   Kid spend = transactions whose category leaf is under the
--   Kids bucket (id 58: Kids Activities, Toys, Babysitter & Daycare)
--   or the Education bucket (id 16: Books & Supplies, Education,
--   Tuition). Rationale: the Kids bucket captures direct kid costs
--   (activities, toys, daycare); the Education bucket is
--   overwhelmingly kid school/college costs (tuition, university
--   fees, ACT/College Board/AP, HS district fees, driving school).
--   A few adult-leaning items (Codecademy ~$383, Aveda ~$91 over
--   6 years) are small relative to the bucket. Investigation of
--   college/HS payees in OTHER buckets found a handful of
--   misclassified items (e.g. "The University Out Arl Web" ~$4.8k
--   under Fast Food, "University Co" ~$434 under Sporting Goods,
--   "Andersonhighschool" ~$26 under Shopping); payee-keyword
--   matching is fragile (false positives such as "Academy Sports"),
--   so v1 keeps the definition category-based. Re-run this seed to
--   refresh if the definition changes.
-- ============================================================

-- 1) previous seed state (cards cascade from dashboards)
DELETE FROM dashboards WHERE slug IN ('overview', 'categories', 'kids', 'tax-savings', 'data-health');
DELETE FROM queries WHERE name IN ('fin_spend_last_month', 'fin_spend_last_month_mom', 'fin_spend_12mo', 'fin_spend_12mo_yoy', 'fin_savings_rate_latest', 'fin_savings_rate_latest_delta', 'fin_kid_share_12mo', 'fin_kid_share_12mo_delta', 'fin_monthly_spend_24m', 'fin_top10_leaf_spend_12mo', 'fin_monthly_totals', 'fin_cat_spend_12mo', 'fin_cat_spend_mom', 'fin_cat_monthly_trend_24m', 'fin_cat_top_payees_12mo', 'fin_cat_recent_txns_12mo', 'fin_bucket_totals_12mo', 'fin_cat_year_spend', 'fin_cat_year_spend_yoy', 'fin_cat_year_monthly', 'fin_cat_year_top_payees', 'fin_cat_year_txns', 'fin_cat_year_bucket_totals', 'fin_kid_spend_12mo', 'fin_kid_spend_12mo_yoy', 'fin_kid_monthly_vs_total_24m', 'fin_kid_spend_by_year', 'fin_kid_top_payees_12mo', 'fin_kid_recent_txns_12mo', 'fin_tax_income_latest', 'fin_tax_income_latest_delta', 'fin_tax_paid_latest', 'fin_tax_paid_latest_delta', 'fin_tax_savings_latest', 'fin_tax_savings_latest_delta', 'fin_tax_income_vs_paid_by_year', 'fin_tax_rate_by_year', 'fin_tax_all_years', 'fin_txn_total', 'fin_last_ingest', 'fin_uncategorized_count', 'fin_load_log', 'fin_pending_suggestions', 'fin_bucket_watch_12mo');

-- 2) saved queries

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_spend_last_month', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest)
SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.txn_date >= w.m0 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)', NULL, 'Spend (cents) in the latest monthly_category_summary month, excl. Transfer/Income');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_spend_last_month_mom', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest)
SELECT (SUM(CASE WHEN t.txn_date >= w.m0 THEN -t.amount_cents ELSE 0 END)
       / NULLIF(SUM(CASE WHEN t.txn_date < w.m0 THEN -t.amount_cents ELSE 0 END), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.txn_date >= DATE_SUB(w.m0, INTERVAL 1 MONTH)', NULL, 'MoM fractional change in spend (latest month vs prior month)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_spend_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)', NULL, 'Spend (cents) over trailing 12 months up to latest mcs month, excl. Transfer/Income');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_spend_12mo_yoy', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT (SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)
       / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)', NULL, 'YoY fractional change in 12-month spend vs prior 12 months');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_savings_rate_latest', 'SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1', NULL, 'Savings rate for the latest tax year (fraction)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_savings_rate_latest_delta', 'SELECT (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1)
     - (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1, 1)', NULL, 'Savings-rate point change, latest tax year vs prior year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_share_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT SUM(CASE WHEN c.parent_id IN (58, 16) THEN -t.amount_cents ELSE 0 END)
     / NULLIF(SUM(-t.amount_cents), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.amount_cents < 0
  AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)', NULL, 'Kid share of 12-month spend (fraction). Kid = Kids + Education buckets');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_share_12mo_delta', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT (SUM(CASE WHEN c.parent_id IN (58, 16) AND t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)
        / NULLIF(SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents END), 0))
     - (SUM(CASE WHEN c.parent_id IN (58, 16) AND t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END)
        / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents END), 0))
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.amount_cents < 0
  AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)', NULL, 'Kid share point change, 12mo vs prior 12mo');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_monthly_spend_24m', 'WITH RECURSIVE latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest),
months AS (
  SELECT DATE_FORMAT(DATE_SUB(w.m0, INTERVAL 23 MONTH), ''%Y-%m'') ym,
         DATE_SUB(w.m0, INTERVAL 23 MONTH) mstart,
         1 n
  FROM win w
  UNION ALL
  SELECT DATE_FORMAT(DATE_ADD(mstart, INTERVAL 1 MONTH), ''%Y-%m''),
         DATE_ADD(mstart, INTERVAL 1 MONTH),
         n + 1
  FROM months
  WHERE n < 24
)
SELECT mo.ym,
       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend
FROM months mo
LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
LEFT JOIN categories c ON c.id = t.category_id
GROUP BY mo.ym, mo.mstart
ORDER BY mo.mstart', NULL, 'Monthly spend (dollars) for 24 months up to latest mcs month, excl. Transfer/Income');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_top10_leaf_spend_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT c.name,
       ROUND(SUM(-t.amount_cents) / 100, 2) spend
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE t.amount_cents < 0
  AND c.parent_id <> 0
  AND c.bucket NOT IN (''Transfer'', ''Income'')
  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)
GROUP BY c.name
ORDER BY spend DESC
LIMIT 10', NULL, 'Top 10 leaf categories by 12-month spend (dollars)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_monthly_totals', 'WITH m AS (
  SELECT mcs.year y, mcs.month mo,
         SUM(CASE WHEN mcs.amount_cents < 0 AND leaf.bucket NOT IN (''Transfer'', ''Income'')
                  THEN -mcs.amount_cents ELSE 0 END) spend_cents,
         SUM(CASE WHEN mcs.amount_cents > 0 AND leaf.bucket = ''Income''
                  THEN mcs.amount_cents ELSE 0 END) deposit_cents
  FROM monthly_category_summary mcs
  JOIN categories leaf ON leaf.id = mcs.category_id
  GROUP BY mcs.year, mcs.month
),
t AS (
  SELECT YEAR(txn_date) y, MONTH(txn_date) mo, COUNT(*) n
  FROM transactions
  GROUP BY y, mo
)
SELECT m.y year, m.mo month, m.spend_cents spend, m.deposit_cents deposits,
       m.deposit_cents - m.spend_cents net, COALESCE(t.n, 0) txn_count
FROM m
LEFT JOIN t ON t.y = m.y AND t.mo = m.mo
ORDER BY m.y DESC, m.mo DESC', NULL, 'Monthly totals: spend/deposits/net (cents, mcs rollup) + txn_count (transactions)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_spend', 'SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND YEAR(t.txn_date) = :year', '{"category": "Food & Dining", "year": "2026"}', 'Spend (cents) in category :category (bucket or leaf) in calendar year :year, excl. Transfer/Income');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_spend_yoy', 'SELECT (COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)
       / NULLIF(COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year - 1 AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND YEAR(t.txn_date) BETWEEN :year - 1 AND :year', '{"category": "Food & Dining", "year": "2026"}', 'YoY fractional spend change in :category for :year vs prior calendar year (NULL when prior year has no data)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_monthly', 'WITH RECURSIVE months AS (
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
LEFT JOIN categories c ON c.id = t.category_id AND (c.bucket = :category OR c.name = :category)
GROUP BY mo.mstart
ORDER BY mo.mstart', '{"category": "Food & Dining", "year": "2026"}', 'Monthly spend (dollars) in category :category for calendar year :year, Jan-Dec spine (months with no data = 0)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_top_payees', 'SELECT t.payee,
       COUNT(*) txn_count,
       COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) total_cents,
       MAX(t.txn_date) last_seen
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND t.amount_cents < 0
  AND YEAR(t.txn_date) = :year
GROUP BY t.payee
ORDER BY total_cents DESC
LIMIT 25', '{"category": "Food & Dining", "year": "2026"}', 'Top payees in category :category in calendar year :year (spend only)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_txns', 'SELECT t.txn_date date,
       t.payee,
       t.description,
       t.amount_cents amount,
       c.name category
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE (c.bucket = :category OR c.name = :category)
  AND YEAR(t.txn_date) = :year
ORDER BY t.txn_date DESC, t.id DESC', '{"category": "Food & Dining", "year": "2026"}', 'All transactions in category :category in calendar year :year (newest first)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_cat_year_bucket_totals', 'WITH sp AS (
  SELECT c.bucket, SUM(-t.amount_cents) cents
  FROM transactions t
  JOIN categories c ON c.id = t.category_id
  WHERE t.amount_cents < 0
    AND YEAR(t.txn_date) = :year
  GROUP BY c.bucket
),
tot AS (SELECT SUM(cents) c FROM sp WHERE bucket NOT IN (''Income'', ''Transfer''))
SELECT b.bucket bucket,
       COALESCE(sp.cents, 0) spend_cents,
       CASE WHEN b.bucket IN (''Income'', ''Transfer'') THEN NULL
            ELSE ROUND(COALESCE(sp.cents, 0) * 100.0 / NULLIF(tot.c, 0), 1) END share_pct
FROM (SELECT DISTINCT bucket FROM categories WHERE parent_id = 0) b
CROSS JOIN tot
LEFT JOIN sp ON sp.bucket = b.bucket
ORDER BY spend_cents DESC', '{"year": "2026"}', 'All 21 buckets: :year spend (cents) + share of spend-bucket total %');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_spend_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0)
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE c.parent_id IN (58, 16)
  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)', NULL, 'Kid spend (cents) over trailing 12 months. Kid = Kids + Education buckets');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_spend_12mo_yoy', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT (SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)
       / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END), 0)) - 1
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE c.parent_id IN (58, 16)
  AND t.amount_cents < 0
  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)', NULL, 'YoY fractional change in kid spend (12mo vs prior 12mo)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_monthly_vs_total_24m', 'WITH RECURSIVE latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest),
months AS (
  SELECT DATE_FORMAT(DATE_SUB(w.m0, INTERVAL 23 MONTH), ''%Y-%m'') ym,
         DATE_SUB(w.m0, INTERVAL 23 MONTH) mstart,
         1 n
  FROM win w
  UNION ALL
  SELECT DATE_FORMAT(DATE_ADD(mstart, INTERVAL 1 MONTH), ''%Y-%m''),
         DATE_ADD(mstart, INTERVAL 1 MONTH),
         n + 1
  FROM months
  WHERE n < 24
),
kid AS (
  SELECT mo.ym,
         COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.parent_id IN (58, 16) THEN -t.amount_cents END), 0) cents
  FROM months mo
  LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
  LEFT JOIN categories c ON c.id = t.category_id
  GROUP BY mo.ym
),
tot AS (
  SELECT mo.ym,
         COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) cents
  FROM months mo
  LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)
  LEFT JOIN categories c ON c.id = t.category_id
  GROUP BY mo.ym
)
SELECT ym, ''Kids'' label, ROUND(cents / 100, 2) amount FROM kid
UNION ALL
SELECT ym, ''Total spend'' label, ROUND(cents / 100, 2) amount FROM tot
ORDER BY ym, label', NULL, 'Monthly kid spend vs total spend (dollars), 24 months, one row per month/series');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_spend_by_year', 'SELECT CAST(YEAR(t.txn_date) AS CHAR) y,
       ROUND(SUM(-t.amount_cents) / 100, 2) spend
FROM transactions t
JOIN categories c ON c.id = t.category_id
WHERE c.parent_id IN (58, 16)
  AND t.amount_cents < 0
GROUP BY y
ORDER BY y', NULL, 'Kid spend (dollars) by calendar year (latest year partial)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_top_payees_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT t.payee, c.name category, COUNT(*) txn_count,
       SUM(-t.amount_cents) total_cents, MAX(t.txn_date) last_seen
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE c.parent_id IN (58, 16)
  AND t.amount_cents < 0
  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)
GROUP BY t.payee, c.name
ORDER BY total_cents DESC
LIMIT 25', NULL, 'Top kid payees over trailing 12 months (Kids + Education buckets)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_kid_recent_txns_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
)
SELECT t.txn_date date, t.payee, t.description, t.amount_cents amount, c.name category
FROM transactions t
JOIN categories c ON c.id = t.category_id
CROSS JOIN win w
WHERE c.parent_id IN (58, 16)
  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)
ORDER BY t.txn_date DESC, t.id DESC', NULL, 'Recent kid transactions (trailing 12 months, newest first)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_income_latest', 'SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1', NULL, 'Income (cents) for the latest tax year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_income_latest_delta', 'SELECT (SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1)
     / NULLIF((SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1', NULL, 'Fractional income change, latest tax year vs prior year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_paid_latest', 'SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1', NULL, 'Income tax paid (cents) for the latest tax year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_paid_latest_delta', 'SELECT (SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1)
     / NULLIF((SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1', NULL, 'Fractional income-tax change, latest tax year vs prior year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_savings_latest', 'SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1', NULL, 'Estimated savings (cents) for the latest tax year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_savings_latest_delta', 'SELECT (SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1)
     / NULLIF((SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1', NULL, 'Fractional est.-savings change, latest tax year vs prior year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_income_vs_paid_by_year', 'SELECT CAST(year AS CHAR) y, ''Income'' label, ROUND(income_cents / 100, 2) amount
FROM tax_years
UNION ALL
SELECT CAST(year AS CHAR) y, ''Tax paid'' label, ROUND(income_tax_paid_cents / 100, 2) amount
FROM tax_years
ORDER BY y, label', NULL, 'Income vs income tax paid (dollars) by year, 2 series');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_rate_by_year', 'SELECT CAST(year AS CHAR) y, ROUND(savings_rate * 100, 2) rate
FROM tax_years
ORDER BY year', NULL, 'Savings rate (%) by year');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_tax_all_years', 'SELECT year, income_cents income, income_tax_paid_cents tax_paid,
       savings_est_cents est_savings, savings_rate rate
FROM tax_years
ORDER BY year DESC', NULL, 'All tax years: income, tax paid, est. savings (cents), savings rate');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_txn_total', 'SELECT COUNT(*) FROM transactions', NULL, 'Total transaction count');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_last_ingest', 'SELECT MAX(ts) FROM load_log', NULL, 'Last ingest timestamp (load_log)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_uncategorized_count', 'SELECT COUNT(*)
FROM transactions
WHERE category_id IS NULL
   OR category_id IN (SELECT id FROM categories WHERE parent_id = 85)', NULL, 'Uncategorized transaction count (Uncategorized bucket or NULL)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_load_log', 'SELECT ts, source_file, adapter, rows_total, rows_new, rows_updated, rows_skipped,
       CONCAT(DATE_FORMAT(date_min, ''%Y-%m-%d''), '' to '', DATE_FORMAT(date_max, ''%Y-%m-%d'')) date_range,
       status
FROM load_log
ORDER BY ts DESC, id DESC
LIMIT 50', NULL, 'Ingest history, newest first');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_pending_suggestions', 'SELECT s.payee, c.name suggested_category, s.confidence, s.rationale
FROM category_suggestions s
LEFT JOIN categories c ON c.id = s.suggested_category_id
WHERE s.status = ''pending''
ORDER BY s.created_at DESC
LIMIT 50', NULL, 'Pending category suggestions (may be empty)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('fin_bucket_watch_12mo', 'WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),
win AS (
  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 1 MONTH) mp1,
         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12
  FROM latest
),
sp AS (
  SELECT c.bucket,
         SUM(CASE WHEN t.txn_date >= w.m0 THEN -t.amount_cents ELSE 0 END) cur_m,
         SUM(CASE WHEN t.txn_date >= w.mp1 AND t.txn_date < w.m0 THEN -t.amount_cents ELSE 0 END) prev_m,
         SUM(CASE WHEN t.txn_date >= w.m12 AND t.txn_date < w.m0 THEN -t.amount_cents ELSE 0 END) cur_12,
         SUM(CASE WHEN t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH) AND t.txn_date < w.m12
                  THEN -t.amount_cents ELSE 0 END) prev_12
  FROM transactions t
  JOIN categories c ON c.id = t.category_id
  CROSS JOIN win w
  WHERE t.amount_cents < 0
    AND c.bucket NOT IN (''Income'', ''Transfer'')
    AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)
  GROUP BY c.bucket
)
SELECT bucket,
       cur_m spend_last_month_cents,
       prev_m spend_prior_month_cents,
       ROUND((cur_m - prev_m) * 100.0 / NULLIF(prev_m, 0), 1) mom_pct,
       cur_12 spend_12mo_cents,
       prev_12 spend_prior_12mo_cents,
       ROUND((cur_12 - prev_12) * 100.0 / NULLIF(prev_12, 0), 1) yoy_pct,
       CASE
         WHEN ABS((cur_m - prev_m) / NULLIF(prev_m, 0)) > 0.30 THEN ''ALERT''
         WHEN ABS((cur_12 - prev_12) / NULLIF(prev_12, 0)) > 0.30 THEN ''ALERT''
         ELSE ''''
       END flag
FROM sp
ORDER BY cur_12 DESC', NULL, 'Per-bucket MoM/YoY spend watch (excl. Income/Transfer); flag=ALERT when |MoM|>30% or |YoY|>30%');

-- overview
INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ('overview', 'Overview', 'Money at a glance: last-month and 12-month spend with MoM/YoY deltas, savings rate, kid share, and monthly totals. Answers ''how did we do last month and over the past year?''', 'finance', 10, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 1, 'label', 'Spend (last month)', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest)\\nSELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.txn_date >= w.m0 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "currency", "delta_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest)\\nSELECT (SUM(CASE WHEN t.txn_date >= w.m0 THEN -t.amount_cents ELSE 0 END)\\n       / NULLIF(SUM(CASE WHEN t.txn_date < w.m0 THEN -t.amount_cents ELSE 0 END), 0)) - 1\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= DATE_SUB(w.m0, INTERVAL 1 MONTH)", "delta_format": "percent", "delta_label": "MoM", "delta_good": "down"}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 2, 'label', 'Spend (12mo)', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "currency", "delta_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT (SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)\\n       / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END), 0)) - 1\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)", "delta_format": "percent", "delta_label": "YoY", "delta_good": "down"}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 3, 'label', 'Savings rate (latest tax year)', NULL, '{"level": 2, "value_query": "SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1", "format": "percent", "delta_query": "SELECT (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1)\\n     - (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1, 1)", "delta_format": "percent", "delta_label": "vs prior yr", "delta_good": "up"}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 4, 'label', 'Kid share of spend (12mo)', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT SUM(CASE WHEN c.parent_id IN (58, 16) THEN -t.amount_cents ELSE 0 END)\\n     / NULLIF(SUM(-t.amount_cents), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0\\n  AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "percent", "delta_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT (SUM(CASE WHEN c.parent_id IN (58, 16) AND t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)\\n        / NULLIF(SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents END), 0))\\n     - (SUM(CASE WHEN c.parent_id IN (58, 16) AND t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END)\\n        / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents END), 0))\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0\\n  AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)", "delta_format": "percent", "delta_label": "vs prior 12mo", "delta_good": "down"}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 5, 'chart', 'Monthly spend (24mo)', (SELECT id FROM queries WHERE name = 'fin_monthly_spend_24m'), '{"data_query": "WITH RECURSIVE latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest),\\nmonths AS (\\n  SELECT DATE_FORMAT(DATE_SUB(w.m0, INTERVAL 23 MONTH), ''%Y-%m'') ym,\\n         DATE_SUB(w.m0, INTERVAL 23 MONTH) mstart,\\n         1 n\\n  FROM win w\\n  UNION ALL\\n  SELECT DATE_FORMAT(DATE_ADD(mstart, INTERVAL 1 MONTH), ''%Y-%m''),\\n         DATE_ADD(mstart, INTERVAL 1 MONTH),\\n         n + 1\\n  FROM months\\n  WHERE n < 24\\n)\\nSELECT mo.ym,\\n       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend\\nFROM months mo\\nLEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\nLEFT JOIN categories c ON c.id = t.category_id\\nGROUP BY mo.ym, mo.mstart\\nORDER BY mo.mstart", "data_map": {"x": "ym", "value": "spend"}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 70, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Spend", "type": "bar", "itemStyle": {"color": "#4f8ef7"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 6, 'chart', 'Top 10 categories (12mo)', (SELECT id FROM queries WHERE name = 'fin_top10_leaf_spend_12mo'), '{"data_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT c.name,\\n       ROUND(SUM(-t.amount_cents) / 100, 2) spend\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0\\n  AND c.parent_id <> 0\\n  AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)\\nGROUP BY c.name\\nORDER BY spend DESC\\nLIMIT 10", "data_map": {"x": "name", "value": "spend"}, "option": {"tooltip": {"trigger": "item", "formatter": "{b}: ${c} ({d}%)"}, "series": [{"name": "Spend (12mo)", "type": "pie", "radius": ["35%", "65%"], "label": {"formatter": "{b}\\n${c}"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'overview'), 7, 'table', 'Monthly totals', (SELECT id FROM queries WHERE name = 'fin_monthly_totals'), '{"formats": {"spend": "currency", "deposits": "currency", "net": "currency", "txn_count": "number"}}');

-- categories
INSERT INTO dashboards (slug, title, description, layout, section, sort_order, is_active) VALUES ('categories', 'Categories', 'Pick a category (bucket or leaf) and a year (or ?category=...&year=...). Year-scoped spend with YoY, monthly spend (bars open Transactions), top payees, transactions, all buckets (rows drill in). Default = top-spend bucket + latest year.', '{"param_nav": [{"param": "category", "label": "Category", "all_label": "Top-spend category (default)", "query": "SELECT name FROM categories WHERE parent_id = 0 ORDER BY name"}, {"param": "year", "label": "Year", "all_label": "Latest year (default)", "query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}]}', 'finance', 20, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'categories'), 1, 'label', 'Spend in :category (:year)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE (c.bucket = :category OR c.name = :category)\\n  AND YEAR(t.txn_date) = :year", "format": "currency", "delta_query": "SELECT (COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0)\\n       / NULLIF(COALESCE(SUM(CASE WHEN YEAR(t.txn_date) = :year - 1 AND t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0), 0)) - 1\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE (c.bucket = :category OR c.name = :category)\\n  AND YEAR(t.txn_date) BETWEEN :year - 1 AND :year", "delta_format": "percent", "delta_label": "YoY", "delta_good": "down", "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}')
,  ((SELECT id FROM dashboards WHERE slug = 'categories'), 2, 'chart', 'Monthly spend in :category (:year)', (SELECT id FROM queries WHERE name = 'fin_cat_year_monthly'), '{"data_query": "WITH RECURSIVE months AS (\\n  SELECT STR_TO_DATE(CONCAT(:year, ''-01-01''), ''%Y-%m-%d'') mstart, 1 n\\n  UNION ALL\\n  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1\\n  FROM months\\n  WHERE n < 12\\n)\\nSELECT DATE_FORMAT(mo.mstart, ''%Y-%m'') ym,\\n       ROUND(COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) / 100, 2) spend\\nFROM months mo\\nLEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\nLEFT JOIN categories c ON c.id = t.category_id AND (c.bucket = :category OR c.name = :category)\\nGROUP BY mo.mstart\\nORDER BY mo.mstart", "data_map": {"x": "ym", "value": "spend"}, "link": {"dashboard": "transactions", "params": {"category": ":category", "month": "{x}"}}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 70, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Spend", "type": "bar", "itemStyle": {"color": "#4f8ef7", "cursor": "pointer"}, "data": []}]}, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}')
,  ((SELECT id FROM dashboards WHERE slug = 'categories'), 3, 'table', 'Top payees in :category (:year)', (SELECT id FROM queries WHERE name = 'fin_cat_year_top_payees'), '{"formats": {"total_cents": "currency", "txn_count": "number", "last_seen": "date"}, "page_size": 250, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}')
,  ((SELECT id FROM dashboards WHERE slug = 'categories'), 4, 'table', 'Transactions in :category (:year)', (SELECT id FROM queries WHERE name = 'fin_cat_year_txns'), '{"formats": {"date": "date", "amount": "currency"}, "page_size": 250, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}')
,  ((SELECT id FROM dashboards WHERE slug = 'categories'), 5, 'table', 'All buckets in :year (click a bucket to drill in)', (SELECT id FROM queries WHERE name = 'fin_cat_year_bucket_totals'), '{"formats": {"spend_cents": "currency", "share_pct": "number"}, "page_size": 250, "links": {"bucket": {"params": {"category": "{bucket}", "year": ":year"}}}, "params": {"category": {"default": "Food & Dining", "allowed_query": "SELECT name FROM categories"}, "year": {"default": "2026", "allowed_query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y ORDER BY y DESC"}}}');


-- kids
INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ('kids', 'Kid costs', 'Kid costs = transactions in the Kids and Education buckets (activities, toys, daycare, tuition, school fees, test prep). Kid spend, share of total spend, and year-over-year trend.', 'finance', 40, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 1, 'label', 'Kid spend (12mo)', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE c.parent_id IN (58, 16)\\n  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "currency"}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 2, 'label', 'Kid share of spend (12mo)', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT SUM(CASE WHEN c.parent_id IN (58, 16) THEN -t.amount_cents ELSE 0 END)\\n     / NULLIF(SUM(-t.amount_cents), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE t.amount_cents < 0\\n  AND c.bucket NOT IN (''Transfer'', ''Income'')\\n  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "percent"}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 3, 'label', 'Kid spend (12mo) vs prior 12mo', NULL, '{"level": 2, "value_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0)\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE c.parent_id IN (58, 16)\\n  AND t.txn_date >= w.m12 AND t.txn_date < DATE_ADD(w.m0, INTERVAL 1 MONTH)", "format": "currency", "delta_query": "WITH latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (\\n  SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0,\\n         DATE_SUB(STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d''), INTERVAL 11 MONTH) m12\\n  FROM latest\\n)\\nSELECT (SUM(CASE WHEN t.txn_date >= w.m12 THEN -t.amount_cents ELSE 0 END)\\n       / NULLIF(SUM(CASE WHEN t.txn_date < w.m12 THEN -t.amount_cents ELSE 0 END), 0)) - 1\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nCROSS JOIN win w\\nWHERE c.parent_id IN (58, 16)\\n  AND t.amount_cents < 0\\n  AND t.txn_date >= DATE_SUB(w.m12, INTERVAL 12 MONTH)", "delta_format": "percent", "delta_label": "YoY", "delta_good": "down"}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 4, 'chart', 'Monthly kid spend vs total (24mo)', (SELECT id FROM queries WHERE name = 'fin_kid_monthly_vs_total_24m'), '{"data_query": "WITH RECURSIVE latest AS (SELECT year ly, month lm FROM monthly_category_summary ORDER BY year DESC, month DESC LIMIT 1),\\nwin AS (SELECT STR_TO_DATE(CONCAT(ly, ''-'', LPAD(lm, 2, ''0''), ''-01''), ''%Y-%m-%d'') m0 FROM latest),\\nmonths AS (\\n  SELECT DATE_FORMAT(DATE_SUB(w.m0, INTERVAL 23 MONTH), ''%Y-%m'') ym,\\n         DATE_SUB(w.m0, INTERVAL 23 MONTH) mstart,\\n         1 n\\n  FROM win w\\n  UNION ALL\\n  SELECT DATE_FORMAT(DATE_ADD(mstart, INTERVAL 1 MONTH), ''%Y-%m''),\\n         DATE_ADD(mstart, INTERVAL 1 MONTH),\\n         n + 1\\n  FROM months\\n  WHERE n < 24\\n),\\nkid AS (\\n  SELECT mo.ym,\\n         COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.parent_id IN (58, 16) THEN -t.amount_cents END), 0) cents\\n  FROM months mo\\n  LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\n  LEFT JOIN categories c ON c.id = t.category_id\\n  GROUP BY mo.ym\\n),\\ntot AS (\\n  SELECT mo.ym,\\n         COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND c.bucket NOT IN (''Transfer'', ''Income'') THEN -t.amount_cents END), 0) cents\\n  FROM months mo\\n  LEFT JOIN transactions t ON t.txn_date >= mo.mstart AND t.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\\n  LEFT JOIN categories c ON c.id = t.category_id\\n  GROUP BY mo.ym\\n)\\nSELECT ym, ''Kids'' label, ROUND(cents / 100, 2) amount FROM kid\\nUNION ALL\\nSELECT ym, ''Total spend'' label, ROUND(cents / 100, 2) amount FROM tot\\nORDER BY ym, label", "data_map": {"x": "ym", "value": "amount", "series": "label"}, "option": {"tooltip": {"trigger": "axis"}, "legend": {"data": ["Kids", "Total spend"]}, "grid": {"left": 70, "right": 20, "top": 40, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Kids", "type": "bar", "itemStyle": {"color": "#f7b84f"}, "data": []}, {"name": "Total spend", "type": "bar", "itemStyle": {"color": "#4f8ef7"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 5, 'chart', 'Kid spend by year', (SELECT id FROM queries WHERE name = 'fin_kid_spend_by_year'), '{"data_query": "SELECT CAST(YEAR(t.txn_date) AS CHAR) y,\\n       ROUND(SUM(-t.amount_cents) / 100, 2) spend\\nFROM transactions t\\nJOIN categories c ON c.id = t.category_id\\nWHERE c.parent_id IN (58, 16)\\n  AND t.amount_cents < 0\\nGROUP BY y\\nORDER BY y", "data_map": {"x": "y", "value": "spend"}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 70, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Spend", "type": "bar", "itemStyle": {"color": "#4f8ef7"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 6, 'table', 'Top kid payees (12mo)', (SELECT id FROM queries WHERE name = 'fin_kid_top_payees_12mo'), '{"formats": {"total_cents": "currency", "last_seen": "date", "txn_count": "number"}, "page_size": 250}'),
  ((SELECT id FROM dashboards WHERE slug = 'kids'), 7, 'table', 'Recent kid transactions (12mo)', (SELECT id FROM queries WHERE name = 'fin_kid_recent_txns_12mo'), '{"formats": {"date": "date", "amount": "currency"}, "page_size": 250}');

-- tax-savings
INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ('tax-savings', 'Tax & savings', 'Income, income tax paid, estimated savings, and savings rate per tax year (from finance.tax_years), with prior-year deltas and charts.', 'finance', 50, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 1, 'label', 'Income (latest tax year)', NULL, '{"level": 2, "value_query": "SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1", "format": "currency", "delta_query": "SELECT (SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1)\\n     / NULLIF((SELECT income_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1", "delta_format": "percent", "delta_label": "vs prior yr", "delta_good": "up"}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 2, 'label', 'Income tax paid (latest tax year)', NULL, '{"level": 2, "value_query": "SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1", "format": "currency", "delta_query": "SELECT (SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1)\\n     / NULLIF((SELECT income_tax_paid_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1", "delta_format": "percent", "delta_label": "vs prior yr", "delta_good": "down"}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 3, 'label', 'Est. savings (latest tax year)', NULL, '{"level": 2, "value_query": "SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1", "format": "currency", "delta_query": "SELECT (SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1)\\n     / NULLIF((SELECT savings_est_cents FROM tax_years ORDER BY year DESC LIMIT 1, 1), 0) - 1", "delta_format": "percent", "delta_label": "vs prior yr", "delta_good": "up"}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 4, 'label', 'Savings rate (latest tax year)', NULL, '{"level": 2, "value_query": "SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1", "format": "percent", "delta_query": "SELECT (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1)\\n     - (SELECT savings_rate FROM tax_years ORDER BY year DESC LIMIT 1, 1)", "delta_format": "percent", "delta_label": "vs prior yr", "delta_good": "up"}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 5, 'chart', 'Income vs tax paid by year', (SELECT id FROM queries WHERE name = 'fin_tax_income_vs_paid_by_year'), '{"data_query": "SELECT CAST(year AS CHAR) y, ''Income'' label, ROUND(income_cents / 100, 2) amount\\nFROM tax_years\\nUNION ALL\\nSELECT CAST(year AS CHAR) y, ''Tax paid'' label, ROUND(income_tax_paid_cents / 100, 2) amount\\nFROM tax_years\\nORDER BY y, label", "data_map": {"x": "y", "value": "amount", "series": "label"}, "option": {"tooltip": {"trigger": "axis"}, "legend": {"data": ["Income", "Tax paid"]}, "grid": {"left": 90, "right": 20, "top": 40, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Income", "type": "bar", "itemStyle": {"color": "#4f8ef7"}, "data": []}, {"name": "Tax paid", "type": "bar", "itemStyle": {"color": "#f76f6f"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 6, 'chart', 'Savings rate % by year', (SELECT id FROM queries WHERE name = 'fin_tax_rate_by_year'), '{"data_query": "SELECT CAST(year AS CHAR) y, ROUND(savings_rate * 100, 2) rate\\nFROM tax_years\\nORDER BY year", "data_map": {"x": "y", "value": "rate"}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 60, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "{value}%"}}, "series": [{"name": "Savings rate %", "type": "line", "smooth": true, "itemStyle": {"color": "#59c376"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'tax-savings'), 7, 'table', 'All tax years', (SELECT id FROM queries WHERE name = 'fin_tax_all_years'), '{"formats": {"income": "currency", "tax_paid": "currency", "est_savings": "currency", "rate": "percent"}}');

-- data-health
INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ('data-health', 'Data health', 'Pipeline and data quality: ingest history, uncategorized counts, pending category suggestions, and per-bucket MoM/YoY spend watch with ALERT flags (|change| > 30%).', 'finance', 70, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 1, 'label', 'Total transactions', NULL, '{"level": 2, "value_query": "SELECT COUNT(*) FROM transactions", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 2, 'label', 'Last ingest', NULL, '{"level": 2, "value_query": "SELECT MAX(ts) FROM load_log", "format": "date"}'),
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 3, 'label', 'Uncategorized transactions', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM transactions\\nWHERE category_id IS NULL\\n   OR category_id IN (SELECT id FROM categories WHERE parent_id = 85)", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 4, 'table', 'Ingest history', (SELECT id FROM queries WHERE name = 'fin_load_log'), '{"formats": {"ts": "date", "rows_total": "number", "rows_new": "number", "rows_updated": "number", "rows_skipped": "number"}}'),
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 5, 'table', 'Pending category suggestions', (SELECT id FROM queries WHERE name = 'fin_pending_suggestions'), '{"formats": {"confidence": "number"}}'),
  ((SELECT id FROM dashboards WHERE slug = 'data-health'), 6, 'table', 'Bucket MoM/YoY watch (12mo)', (SELECT id FROM queries WHERE name = 'fin_bucket_watch_12mo'), '{"formats": {"spend_last_month_cents": "currency", "spend_prior_month_cents": "currency", "spend_12mo_cents": "currency", "spend_prior_12mo_cents": "currency"}}');

-- done: 5 dashboards, 38 queries, 32 cards
