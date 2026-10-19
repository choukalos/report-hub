-- 0002_dashboard_groups.sql — group dashboards on the landing page
--
-- Adds `section` (landing-page group heading key) + `sort_order` to
-- `dashboards` so the index page can render grouped sections (Finance,
-- Data Hub, Demo) instead of one flat list. AI-managed: seeds set the
-- values; the UI never writes.
-- Convention: no semicolons inside string literals (runner splits on ;).

ALTER TABLE dashboards
  ADD COLUMN section VARCHAR(40) NOT NULL DEFAULT 'general' AFTER layout,
  ADD COLUMN sort_order INT NOT NULL DEFAULT 100 AFTER section;

CREATE INDEX idx_dashboards_section ON dashboards (section, sort_order);