# report-hub

Strictly **read-only** reporting UI over the homelab MySQL data.
Companion: [data-hub](../data-hub) (ingest/ETL, the only writer).
Architecture doc: `homelab/data-hub/ARCHITECTURE.md`.

## Read-only contract (important)

- The UI performs **no writes** — no login, no forms, no edit endpoints.
- Dashboards, cards, and saved queries are **created and managed by the AI**
  by inserting rows into the `reports` database (`queries`, `dashboards`,
  `cards`). That is the only way content appears here.
- The MySQL user (`dh_reports`) is `SELECT`-only on `finance.*` and owns
  `reports.*` (used only by the migration runner and the AI).
- The query engine enforces: single SELECT/WITH statements, no DDL/DML,
  no `INTO OUTFILE`/`LOAD_FILE`/`SLEEP`/system schemas, no locking reads
  (`FOR UPDATE`/`FOR SHARE`/`LOCK IN SHARE MODE`), statement timeout,
  and hard row caps (250/page default, 1000 max; 500 for preview).

So: to change a report, ask the AI — it edits the rows in `reports.*`.

## Generic card model

A dashboard is an ordered set of cards; each card binds to a saved SQL
query (any data in MySQL, not just finance):

| type | config |
|---|---|
| `label` | `{"level": 1-4, "text": "...", "value_query": "SELECT ...", "format": "currency\|date\|number\|percent\|text", "delta_query": "SELECT ...", "delta_format": "...", "delta_label": "MoM", "delta_good": "down\|up"}` — all keys optional: plain heading (`text` + `level`) or KPI (single-value `value_query` + optional MoM/YoY `delta_query` rendered with an up/down arrow, green when the delta is good / red when bad; `delta_good: "down"` = a falling value is good, the default) |
| `table` | `{"page_size": 250, "formats": {"col": "currency\|date\|number\|text"}, "hide": ["col"]}` — paginated 250/page (max 1000) with prev/next + page X of Y + total rows; per-column formats; hidden columns omitted |
| `chart` | `{"chart": "bar\|column\|pie", "option": {<full ECharts option>}}` — bar/column/pie rendered client-side by ECharts; data is self-contained in the option; `query_id` is optional provenance |

Chart titles, legend show/hide, series names/colors/visibility all live in
the ECharts `option` JSON (rendered client-side by ECharts).

## Run

```sh
# one-time (renders SQL from homelab/.env, pipes to sudo mysql)
bash /home/chuck/homelab/data-hub/provision.sh

cd /home/chuck/homelab/compose
docker compose -f compose.data-hub.yml up -d --build report-hub
# browse: http://thor.local:8101
```

## API (all read-only)

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | dashboard index |
| GET | `/d/{slug}?page=N` | render dashboard |
| GET | `/api/health` | liveness |
| GET | `/api/dashboards` | list dashboards |
| GET | `/api/dashboards/{slug}/cards` | card list + config |
| GET | `/api/queries` | saved queries |
| POST | `/api/queries/{id}/run?page=&page_size=&sort=` | run saved query (paginated) |
| POST | `/api/preview` | ad-hoc SELECT, AI scratch work (`{"sql": "..."}`, 500-row cap) |

## Repo layout

```
migrations/reports/   metadata schema (0001_init.sql)
server/
  main.py             FastAPI app + card rendering
  query_engine.py     read-only query guards + pagination
  db.py               connections + migration runner
templates/            Jinja2 (base / index / dashboard)
static/               app.css + vendored echarts.min.js (offline)
```