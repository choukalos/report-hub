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
| `chart` | `{"option": {<full ECharts option>}}` — ECharts option rendered client-side. **Live data:** add `"data_query": "SELECT ..."` (inline) and/or set the card's `query_id`, plus `"data_map": {"x": "label_col", "value": "value_col", "series": "group_col"?}` — at render time the query runs through the same query engine (caps/timeout) and the server fills `option.series[i].data` (and `xAxis.data` for bar/column) from the rows; everything else in `option` is left as authored. Without `data_query`/`query_id` the option's static data is used (phase-3 behavior). |

Chart titles, legend show/hide, series names/colors/visibility all live in
the ECharts `option` JSON (rendered client-side by ECharts).

### Live chart data (`data_query` + `data_map`)

A chart card can pull its data at render time instead of hard-coding it:

- `config.data_query`: an inline SELECT (or the card's `query_id` if
  `data_query` is absent) — run through the same read-only query engine
  (row cap 500, statement timeout) every time the dashboard renders.
- `config.data_map`: `{"x": <label column>, "value": <value column>,
  "series": <grouping column, optional>}`
  - **no `series`**: one series; values in row order; the `x` column
    becomes the xAxis categories (bar/column). For pie, data is
    `[{name: x, value: v}]`.
  - **with `series`**: one series per distinct `series` value (first-seen
    order, matched by index into `option.series`); shared x labels.
- The server fills only `option.series[i].data` (+ `xAxis.data` for
  bar/column); the rest of the option is exactly as authored.
- Money: chart values are dollars (divide cents by 100 in the SQL) so
  axes stay readable; tables present integer cents via the `currency`
  format.

### `?category=` (safe single-param substitution)

Cards may declare `config.params`: `{"name": "default"}` or
`{"name": {"default": "X", "allowed_query": "SELECT ..."}}`. Queries and
`data_query` may then contain `:name` placeholders. At render time each
declared param is resolved from the request's query string (e.g.
`/d/categories?category=Food%20%26%20Dining`); only **declared** params
are substituted, values are quote-escaped (no raw string interpolation),
and with `allowed_query` a request value outside the allowed set (first
column, TTL-cached) falls back to the default. Undeclared placeholders
are never substituted (they fail validation/execution, never inject).

## v1 dashboards (finance)

Seeded by `seed/v1_finance_dashboards.sql` (idempotent — delete-then-insert
per slug; safe to re-run). All money = integer cents in finance, presented
as dollars; spend = SUM of negative (debit) amounts shown as positive,
excluding the Transfer and Income buckets. "Last/trailing 12 months" is
derived in SQL from the latest month in `finance.monthly_category_summary`
(no hardcoded dates).

| slug | what it answers |
|---|---|
| `/d/overview` | "How did we do last month and over the past year?" — spend (last month, 12mo) with MoM/YoY deltas, savings rate (latest tax year), kid share of spend, monthly spend (24mo), top-10 leaf categories (12mo), monthly totals. |
| `/d/categories?category=<Bucket Name>` | "Where does the money go in one bucket?" — 12mo spend + MoM, 24mo trend, top payees, recent transactions (250/page), all-21-bucket comparison. `?category=` takes a top-level bucket name (URL-encoded, e.g. `?category=Food%20%26%20Dining`); defaults to the top-spend bucket (Auto & Transport as of seed time); unknown values fall back to the default. |
| `/d/kids` | "What are we spending on the kids?" — kid spend 12mo, share of total spend, YoY, monthly kid-vs-total (24mo), by year, top kid payees, recent kid transactions. **Kid definition (v1):** categories under the **Kids** bucket (activities, toys, daycare) **or the Education bucket** (tuition, school fees, test prep) — see the seed file's header comment for the investigation and rationale. |
| `/d/tax-savings` | "What's the income/tax/savings trajectory?" — latest tax-year KPIs (income, tax paid, est. savings, savings rate) with prior-year deltas, income-vs-tax by year, savings-rate line, all years table (from `finance.tax_years`). |
| `/d/data-health` | "Is the pipeline and the data healthy?" — total transactions, last ingest, uncategorized count, ingest history, pending category suggestions (renders empty state when none), and a per-bucket MoM/YoY spend watch with an `ALERT` flag when the MoM or YoY change exceeds 30% (in either direction). |

## v3 dashboards

Seeded by `seed/v3_yearly_review.sql` + `seed/v3_datahub.sql`
(idempotent — delete-then-insert per slug; safe to re-run). Same money
conventions as v1.

| slug | what it answers |
|---|---|
| `/d/yearly?year=<YYYY>` | "What did we spend in a given year?" — full-year spend with YoY delta vs the prior calendar year, txn count, monthly spend (Jan–Dec), category mix (top 10 + Other), spend by year (all data), category/payee/monthly summaries, all transactions for the year (250/page). `?year=` takes a year present in `finance.transactions` (URL-encoded not needed); the selector lists every year in the data (2021+ as of seed time); default = latest year in the data (2026, partial); unknown values fall back to the default. Re-run the seed to refresh the default when a new year lands. |
| `/d/datahub` | "What's in the generic data hub?" — active-dataset count, rows loaded (all time), rows-loaded-by-day (90d), dataset registry (`hub.datasets`), ingest history (`hub.load_log`). Static SQL only — always valid. |
| `/d/demo-weather` | v3 demo: a dashboard over a hub generic dataset (`hub.ds_demo-weather`, 14 sample daily readings — demo data, not a real sensor). Proves the per-dataset pattern below end-to-end. |

### Dashboard over a hub dataset (v3 pattern)

The engine substitutes `:param` placeholders as **escaped string
literals only**, so a dashboard cannot reference a dynamic
`hub.ds_<name>` table via a param (a table name is not a string value).
Per-dataset dashboards are therefore **generated per dataset** with
static SQL against the concrete target table — the normal AI-managed
workflow:

1. Register the dataset in data-hub (`POST /api/datasets`, or drop a CSV
   in the inbox and let the watcher infer it) → target table
   `hub.ds_<name>`.
2. Insert a `dashboards` row + `cards` rows whose SQL references
   `hub.ds_<name>` (fully qualified; card queries run on the finance
   connection and `dh_reports` has SELECT on `hub.*`). Backtick-qualify
   the table name — dataset slugs allow hyphens
   (``SELECT ... FROM `hub`.`ds_my-dataset` ``).
3. Keep the SQL generic-friendly: the adapter always adds `id`
   (PK), `content_hash`, `ingested_at` columns; data columns are the
   slugified CSV headers (`id` → `col_id`).
4. Seed it in a versioned file (`seed/v3_*.sql`, idempotent) so the
   dashboard survives a `reports` db rebuild.

`/d/demo-weather` is the reference example (dual-series chart + raw
table). To retire a dataset's dashboard: delete the dashboard slug
(cards cascade), then `DELETE /api/datasets/<name>` + drop the table in
data-hub.

## How to add a dashboard

1. Ask the AI (or do it yourself as `dh_reports`): insert a `queries` row
   per saved query, a `dashboards` row, and `cards` rows referencing the
   queries (`query_id` for tables/charts, inline `data_query` for charts,
   `value_query`/`delta_query` inline SELECTs for KPI labels).
2. Rebuild is **not** needed — content is read from the DB at render time.
   (Rebuild only when `server/` or `templates/` change.)
3. To refresh the static bits of the v1 finance dashboards (e.g. after
   the `?category=` default or the kid definition changes), re-run the
   versioned seed: `mysql -h thor.local -u dh_reports -p reports <
   seed/v1_finance_dashboards.sql`. v3 seeds work the same way
   (`seed/v3_yearly_review.sql`, `seed/v3_datahub.sql`).

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
seed/
  v1_finance_dashboards.sql  idempotent seed: 5 v1 finance dashboards + queries + cards
server/
  main.py             FastAPI app + card rendering
  query_engine.py     read-only query guards + pagination + :param substitution
  db.py               connections + migration runner
templates/            Jinja2 (base / index / dashboard)
static/               app.css + vendored echarts.min.js (offline)
```