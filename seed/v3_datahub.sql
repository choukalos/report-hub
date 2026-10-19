-- ==========================================================
-- v3 data-hub dashboards seed (report-hub)
--
-- Seeds two dashboards into the `reports` database:
--   * `datahub`      — static overview of the v2 generic-dataset
--                      pipeline: dataset registry (hub.datasets),
--                      ingest history (hub.load_log), rows loaded
--                      by day. Always valid — no dynamic table refs.
--   * `demo-weather` — per-dataset dashboard over the demo dataset
--                      `demo-weather` (hub.ds_demo-weather, 14 sample
--                      daily readings; demo data, not a real sensor).
--                      Demonstrates the v3 per-dataset pattern:
--                      the engine substitutes params as escaped
--                      string literals only, so a dashboard cannot
--                      reference a dynamic hub.ds_<name> table via a
--                      param — per-dataset dashboards are generated
--                      per dataset with static SQL (see README,
--                      "Dashboard over a hub dataset").
--
-- IDEMPOTENT: delete-then-insert per dashboard slug; safe to re-run.
-- Apply manually as dh_reports (NOT via the migration runner):
--   mysql -h thor.local -u dh_reports -p reports < seed/v3_datahub.sql
--
-- Conventions
--   * Card queries run on the finance connection; hub tables are
--     referenced fully qualified (dh_reports has SELECT on hub.*).
--   * Timestamps rendered via the "date" card format.
-- ============================================================

-- 1) previous seed state (cards cascade from dashboards)
DELETE FROM dashboards WHERE slug IN ('datahub', 'demo-weather');
DELETE FROM queries WHERE name IN ('hub_datasets_registry', 'hub_load_log', 'hub_rows_by_day_90d', 'demo_weather_readings', 'demo_weather_chart');

-- 2) saved queries

INSERT INTO queries (name, sql_text, params, description) VALUES ('hub_datasets_registry', 'SELECT name,
       description,
       source_pattern,
       target_table,
       is_active,
       created_at,
       updated_at
FROM hub.datasets
ORDER BY is_active DESC, name', NULL, 'Generic dataset registry (hub.datasets), active first');

INSERT INTO queries (name, sql_text, params, description) VALUES ('hub_load_log', 'SELECT ts,
       dataset_name,
       source_file,
       adapter,
       rows_total,
       rows_new,
       rows_updated,
       rows_skipped,
       status,
       issues
FROM hub.load_log
ORDER BY ts DESC, id DESC', NULL, 'Generic pipeline ingest history (hub.load_log), newest first');

INSERT INTO queries (name, sql_text, params, description) VALUES ('hub_rows_by_day_90d', 'WITH RECURSIVE days AS (
  SELECT COALESCE((SELECT MAX(DATE(ts)) FROM hub.load_log), CURDATE()) d, 1 n
  UNION ALL
  SELECT DATE_SUB(d, INTERVAL 1 DAY), n + 1
  FROM days
  WHERE n < 90
)
SELECT DATE_FORMAT(days.d, ''%Y-%m-%d'') day,
       COALESCE(SUM(ll.rows_total), 0) rows_loaded
FROM days
LEFT JOIN hub.load_log ll ON DATE(ll.ts) = days.d
GROUP BY days.d
ORDER BY days.d', NULL, 'Rows loaded by day, trailing 90 days (hub.load_log)');

INSERT INTO queries (name, sql_text, params, description) VALUES ('demo_weather_readings', 'SELECT date,
       temp_c,
       humidity_pct
FROM hub.`ds_demo-weather`
ORDER BY date DESC', NULL, 'Demo dataset readings (hub.ds_demo-weather), newest first');

INSERT INTO queries (name, sql_text, params, description) VALUES ('demo_weather_chart', 'SELECT DATE_FORMAT(date, ''%Y-%m-%d'') day,
       ''Temp (C)'' label,
       CAST(temp_c AS DECIMAL(10, 2)) v,
       0 so
FROM hub.`ds_demo-weather`
UNION ALL
SELECT DATE_FORMAT(date, ''%Y-%m-%d''),
       ''Humidity (%)'',
       CAST(humidity_pct AS DECIMAL(10, 2)),
       1
FROM hub.`ds_demo-weather`
ORDER BY day, so', NULL, 'Demo dataset long format: one row per day/series (series order: temp, then humidity)');

-- 3) datahub dashboard + cards

INSERT INTO dashboards (slug, title, description, layout, section, sort_order, is_active) VALUES ('datahub', 'Data Hub', 'The v2 generic-dataset pipeline: what''s registered (hub.datasets) and what''s been ingested (hub.load_log). Per-dataset dashboards (like Demo Weather) are generated per dataset — see the report-hub README.', NULL, 'datahub', 10, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'datahub'), 1, 'label', 'Active datasets', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM hub.datasets\\nWHERE is_active = 1", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'datahub'), 2, 'label', 'Rows loaded (all time)', NULL, '{"level": 2, "value_query": "SELECT COALESCE(SUM(rows_total), 0)\\nFROM hub.load_log", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'datahub'), 3, 'chart', 'Rows loaded by day (90d)', (SELECT id FROM queries WHERE name = 'hub_rows_by_day_90d'), '{"data_query": "WITH RECURSIVE days AS (\\n  SELECT COALESCE((SELECT MAX(DATE(ts)) FROM hub.load_log), CURDATE()) d, 1 n\\n  UNION ALL\\n  SELECT DATE_SUB(d, INTERVAL 1 DAY), n + 1\\n  FROM days\\n  WHERE n < 90\\n)\\nSELECT DATE_FORMAT(days.d, ''%Y-%m-%d'') day,\\n       COALESCE(SUM(ll.rows_total), 0) rows_loaded\\nFROM days\\nLEFT JOIN hub.load_log ll ON DATE(ll.ts) = days.d\\nGROUP BY days.d\\nORDER BY days.d", "data_map": {"x": "day", "value": "rows_loaded"}, "option": {"tooltip": {"trigger": "axis"}, "grid": {"left": 60, "right": 20, "top": 30, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}}, "series": [{"name": "Rows loaded", "type": "bar", "itemStyle": {"color": "#8b5cf6"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'datahub'), 4, 'table', 'Dataset registry', (SELECT id FROM queries WHERE name = 'hub_datasets_registry'), '{"formats": {"created_at": "date", "updated_at": "date", "is_active": "number"}, "page_size": 250}'),
  ((SELECT id FROM dashboards WHERE slug = 'datahub'), 5, 'table', 'Ingest history', (SELECT id FROM queries WHERE name = 'hub_load_log'), '{"formats": {"ts": "date"}, "page_size": 250}');

-- 4) demo-weather dashboard + cards

INSERT INTO dashboards (slug, title, description, layout, section, sort_order, is_active) VALUES ('demo-weather', 'Demo Weather (hub dataset)', 'v3 demo: a report-hub dashboard over a hub generic dataset (hub.ds_demo-weather — 14 sample daily readings; demo data, not a real sensor). Pattern: register the dataset in data-hub, drop CSVs into the inbox, generate a dashboard like this one.', NULL, 'demo', 10, 1);

INSERT INTO cards (dashboard_id, position, type, title, query_id, config)
VALUES
  ((SELECT id FROM dashboards WHERE slug = 'demo-weather'), 1, 'label', 'Readings', NULL, '{"level": 2, "value_query": "SELECT COUNT(*)\\nFROM hub.`ds_demo-weather`", "format": "number"}'),
  ((SELECT id FROM dashboards WHERE slug = 'demo-weather'), 2, 'label', 'Date range', NULL, '{"level": 2, "value_query": "SELECT CONCAT(MIN(date), '' to '', MAX(date))\\nFROM hub.`ds_demo-weather`", "format": "text"}'),
  ((SELECT id FROM dashboards WHERE slug = 'demo-weather'), 3, 'chart', 'Daily temp & humidity', (SELECT id FROM queries WHERE name = 'demo_weather_chart'), '{"data_query": "SELECT DATE_FORMAT(date, ''%Y-%m-%d'') day,\\n       ''Temp (C)'' label,\\n       CAST(temp_c AS DECIMAL(10, 2)) v,\\n       0 so\\nFROM hub.`ds_demo-weather`\\nUNION ALL\\nSELECT DATE_FORMAT(date, ''%Y-%m-%d''),\\n       ''Humidity (%)'',\\n       CAST(humidity_pct AS DECIMAL(10, 2)),\\n       1\\nFROM hub.`ds_demo-weather`\\nORDER BY day, so", "data_map": {"x": "day", "value": "v", "series": "label"}, "option": {"tooltip": {"trigger": "axis"}, "legend": {"top": 0}, "grid": {"left": 50, "right": 50, "top": 40, "bottom": 55}, "xAxis": {"type": "category", "axisLabel": {"rotate": 45}}, "yAxis": [{"type": "value", "name": "temp (C)", "axisLabel": {"formatter": "${value}"}}, {"type": "value", "name": "humidity (%)", "min": 40, "max": 100, "axisLabel": {"formatter": "${value}"}}], "series": [{"name": "Temp (C)", "type": "line", "itemStyle": {"color": "#e07b39"}, "data": []}, {"name": "Humidity (%)", "type": "line", "yAxisIndex": 1, "itemStyle": {"color": "#4f8ef7"}, "data": []}]}}'),
  ((SELECT id FROM dashboards WHERE slug = 'demo-weather'), 4, 'table', 'Readings', (SELECT id FROM queries WHERE name = 'demo_weather_readings'), '{"formats": {"date": "date"}, "page_size": 250}');