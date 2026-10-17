-- 0001_init.sql — reports metadata schema v1
-- READ-ONLY CONTRACT: the report-hub UI performs NO writes to this schema.
-- All inserts/updates/deletes here are done by the AI (direct SQL or via
-- tooling). See report-hub README.md.
-- Convention: no semicolons inside string literals (runner splits on ';').

CREATE TABLE IF NOT EXISTS queries (
  id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name          VARCHAR(120) NOT NULL,
  sql_text      TEXT NOT NULL,
  params        JSON NULL,
  description   VARCHAR(255) NOT NULL DEFAULT '',
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_queries_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboards (
  id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  slug          VARCHAR(80) NOT NULL,
  title         VARCHAR(120) NOT NULL,
  description   VARCHAR(255) NOT NULL DEFAULT '',
  layout        JSON NULL,
  is_active     TINYINT(1) NOT NULL DEFAULT 1,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_dashboards_slug (slug)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Card types:
--   label: config = {"level": 1-4, "text": "...", "value_query": "SELECT ...",
--                            "format": "currency|number|percent|text"}
--   table: config = {"page_size": 250, "formats": {"col": "currency|date|number|text"},
--                            "hide": ["col"]}
--   chart: config = {"chart": "bar|column|pie", "option": {<full ECharts option>}}
-- Legend show/hide, series names/colors/visibility live inside the ECharts option.
CREATE TABLE IF NOT EXISTS cards (
  id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  dashboard_id  INT UNSIGNED NOT NULL,
  position      INT NOT NULL DEFAULT 0,
  type          ENUM('label','table','chart') NOT NULL,
  title         VARCHAR(120) NOT NULL DEFAULT '',
  query_id      INT UNSIGNED NULL,
  config        JSON NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_cards_dashboard (dashboard_id, position),
  CONSTRAINT fk_cards_dashboard FOREIGN KEY (dashboard_id) REFERENCES dashboards (id) ON DELETE CASCADE,
  CONSTRAINT fk_cards_query FOREIGN KEY (query_id) REFERENCES queries (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;