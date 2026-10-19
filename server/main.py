import copy
import datetime
import json
import math
import os
import re
import sys
import time
from contextlib import asynccontextmanager
from urllib.parse import urlencode

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

import jinja2

from . import config, db, query_engine

TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "..", "templates")
STATIC_DIR = os.path.join(os.path.dirname(__file__), "..", "static")
MIGRATIONS_DIR = os.path.join(os.path.dirname(__file__), "..", "migrations", "reports")

jinja = jinja2.Environment(loader=jinja2.FileSystemLoader(TEMPLATES_DIR), autoescape=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    conn = db.connect_with_retry(config.REPORTS_DB)
    try:
        app.state.migrations_applied = db.apply_migrations(MIGRATIONS_DIR, config.REPORTS_DB, conn)
    finally:
        conn.close()
    yield


app = FastAPI(title="report-hub", version="0.1.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _reports_conn():
    return db.get_conn(config.REPORTS_DB)


def _fmt(value, fmt):
    """Format a cell value for display (cents-based money, etc.)."""
    if value is None:
        return "—"
    if fmt == "date":
        if isinstance(value, datetime.datetime):
            return value.strftime("%Y-%m-%d %H:%M")
        if isinstance(value, datetime.date):
            return value.isoformat()
        return str(value)
    try:
        if fmt == "currency":
            v = int(value) / 100
            return f"-${abs(v):,.2f}" if v < 0 else f"${v:,.2f}"
        if fmt == "percent":
            return f"{float(value) * 100:,.1f}%"
        if fmt == "number":
            return f"{int(value):,}"
    except (TypeError, ValueError):
        pass
    return str(value)


def _query_sql(query_id: int) -> str:
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT sql_text FROM queries WHERE id = %s", (query_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "query not found")
        return row["sql_text"]
    finally:
        conn.close()


_ALLOWED_CACHE: dict = {}  # allowed_query sql -> (monotonic, set of values)
_ALLOWED_CACHE_TTL = 300  # seconds


def _allowed_set(sql: str) -> set:
    """First-column values of an allowed_query (TTL-cached)."""
    now = time.monotonic()
    hit = _ALLOWED_CACHE.get(sql)
    if hit and now - hit[0] < _ALLOWED_CACHE_TTL:
        return hit[1]
    res = query_engine.run_preview(sql, limit=500)
    allowed = {str(r[res["columns"][0]]) for r in res["rows"]}
    _ALLOWED_CACHE[sql] = (now, allowed)
    return allowed


def _resolve_card_params(cfg: dict, request_params: dict) -> dict:
    """Resolve a card's declared ``config.params`` against request query params.

    Declared forms (per param name):
      - ``"default"`` — plain string default.
      - ``{"default": "X", "allowed_query": "SELECT ..."}`` — the request
        value is validated against the first column of ``allowed_query``
        (run through the same read-only query engine); a value outside the
        allowed set falls back to the default.

    Every declared name is always resolved to a concrete string so that all
    ``:name`` placeholders in the card's SQL get substituted (never left
    raw). Missing/blank request values use the default.
    """
    declared = cfg.get("params") or {}
    resolved = {}
    for name, spec in declared.items():
        if isinstance(spec, dict):
            default = spec.get("default")
            allowed_query = spec.get("allowed_query")
        else:
            default, allowed_query = spec, None
        raw = request_params.get(name)
        raw = raw.strip() if isinstance(raw, str) else None
        if raw:
            value = raw
            if allowed_query:
                allowed = _allowed_set(allowed_query)
                if value not in allowed:
                    value = default if default is not None else ""
        else:
            value = default if default is not None else ""
        resolved[name] = str(value)
    return resolved


def _apply_chart_data(option: dict, result: dict, data_map: dict) -> dict:
    """Fill ``option.series[*].data`` (and ``xAxis.data`` for bar/column)
    from live query rows. Only ``data`` is filled — the rest of the ECharts
    option is left exactly as authored.

    ``data_map`` keys: ``x`` (label column), ``value`` (value column),
    ``series`` (optional grouping column).
      - no ``series``: one series; values in row order; x labels from the
        ``x`` column become xAxis categories for bar/column (ignored for
        pie, where data is ``[{name: x, value: v}]``).
      - with ``series``: one series per distinct ``series`` value (first-
        seen order, matched by index into ``option.series``); shared x
        labels = distinct x values in first-seen order. Pie data uses the
        ``series`` value as the name when present.
    """
    xcol = data_map.get("x")
    vcol = data_map.get("value")
    scol = data_map.get("series")
    if not xcol or not vcol:
        raise ValueError("chart data_map requires 'x' and 'value'")
    columns = result["columns"]
    rows = result["rows"]
    missing = [c for c in (xcol, vcol, scol) if c and c not in columns]
    if missing:
        raise ValueError(f"chart data_map columns not in query result: {', '.join(missing)}")

    series_list = option.get("series")
    if not isinstance(series_list, list) or not series_list:
        raise ValueError("chart option has no series to fill")

    def _num(v):
        if v is None:
            return 0
        if isinstance(v, (int, float)):
            return v
        try:
            return float(v)
        except (TypeError, ValueError):
            return v

    is_pie = series_list[0].get("type") == "pie"
    if scol:
        svals = []
        xlabels = []
        for r in rows:
            sv = r[scol]
            if sv not in svals:
                svals.append(sv)
            xv = str(r[xcol])
            if xv not in xlabels:
                xlabels.append(xv)
        if is_pie:
            series_list[0]["data"] = [
                {"name": str(r[scol]), "value": _num(r[vcol])} for r in rows
            ]
        else:
            if len(svals) > len(series_list):
                raise ValueError("more series in data than option.series slots")
            for i, sv in enumerate(svals):
                series_list[i]["data"] = [_num(r[vcol]) for r in rows if r[scol] == sv]
    else:
        xlabels = [str(r[xcol]) for r in rows]
        if is_pie:
            series_list[0]["data"] = [
                {"name": str(r[xcol]), "value": _num(r[vcol])} for r in rows
            ]
        else:
            series_list[0]["data"] = [_num(r[vcol]) for r in rows]

    if not is_pie:
        xa = option.get("xAxis")
        if isinstance(xa, dict):
            xa["data"] = xlabels
        elif isinstance(xa, list) and xa and isinstance(xa[0], dict):
            xa[0]["data"] = xlabels
    return option


def _build_param_nav(layout, request_params: dict, slug: str = ""):
    """Normalize a dashboard's ``layout.param_nav`` into a list of picker items.

    ``param_nav`` may be a single dict (legacy form) or a LIST of
    ``{param, label, all_label, query}`` entries. Each item's ``query``
    (run read-only) lists the selectable values for its request param.

    Per item, ``other_params`` carries the remaining request params
    (excluding ``page`` and the item's own param) so the template's
    onchange/reset preserve them; ``reset_qs`` is the URL-encoded form of
    that dict for the reset link. Returns a list of items, or None when
    nothing usable is declared.
    """
    if isinstance(layout, str):
        try:
            layout = json.loads(layout)
        except (TypeError, ValueError):
            layout = None
    nav = (layout or {}).get("param_nav") if isinstance(layout, dict) else None
    if isinstance(nav, dict):  # legacy single-dict form
        nav = [nav]
    if not isinstance(nav, list):
        return None
    items = []
    for entry in nav:
        if not (isinstance(entry, dict) and entry.get("param") and entry.get("query")):
            continue
        try:
            res = query_engine.run_preview(entry["query"], limit=200)
            col = res["columns"][0]
            values = [r[col] for r in res["rows"] if r.get(col) is not None]
            current = request_params.get(entry["param"]) or ""
            if current and current not in values:
                values = [current] + values
            other = {
                k: v for k, v in request_params.items()
                if k != "page" and k != entry["param"]
            }
            items.append(
                {
                    "param": entry["param"],
                    "label": entry.get("label") or entry["param"],
                    "all_label": entry.get("all_label") or "(default)",
                    "values": values,
                    "current": current,
                    "other_params": other,
                    "reset_qs": urlencode(other),
                }
            )
        except Exception as e:  # nav is cosmetic — never kill the page
            print(f"param_nav failed for {slug}: {e}", file=sys.stderr)
    return items or None


def _link_value(spec, row: dict, params: dict):
    """Resolve one link ``value_spec`` to a concrete string.

    ``"{col}"`` -> the row's value for column ``col`` (typically the linked
    column's own value); ``":name"`` -> the card's RESOLVED param value
    (effective value after validation/fallback); anything else is a
    literal string.
    """
    if isinstance(spec, str):
        m = re.fullmatch(r"\{([^{}]+)\}", spec)
        if m and m.group(1) in row:
            v = row[m.group(1)]
            return "" if v is None else str(v)
        if spec.startswith(":") and spec[1:] in params:
            return str(params[spec[1:]])
        return spec
    return "" if spec is None else str(spec)


def _build_link_href(spec, row: dict, linked_col: str, params: dict, slug: str):
    """Build a server-side drill-down href for one table row link.

    ``spec`` forms:
      - legacy string ``target_param``: same dashboard,
        ``?target_param=<linked column's row value>`` (kept working).
      - dict ``{dashboard?: str, params: {target_param: value_spec}}``:
        ``dashboard`` omitted/empty = same dashboard (``?qs``), else
        ``/d/<dashboard>?qs``. Values are URL-encoded.

    Returns None for unusable specs.
    """
    if isinstance(spec, str):
        if not spec:
            return None
        value = row.get(linked_col)
        return "?" + urlencode({spec: "" if value is None else str(value)})
    if isinstance(spec, dict):
        target = spec.get("dashboard") or ""
        link_params = spec.get("params") or {}
        if not isinstance(link_params, dict) or not link_params:
            return None
        values = {k: _link_value(v, row, params) for k, v in link_params.items()}
        qs = urlencode(values)
        if target and target != slug:
            return f"/d/{target}" + (f"?{qs}" if qs else "")
        return "?" + qs
    return None


def _render_card(card: dict, page: int, request_params: dict | None = None, slug: str = "") -> dict:
    """Render one card into template-ready data (query + config -> payload).

    ``request_params`` are the dashboard route's query params (e.g.
    ``category``); a card's declared ``config.params`` are resolved against
    them and substituted into the card's SQL (see ``_resolve_card_params``
    and ``query_engine.substitute_params``). ``slug`` is the dashboard's
    slug, used to build server-side drill-down link hrefs (same-dashboard
    vs cross-dashboard).
    """
    request_params = request_params or {}
    out = {
        "id": card["id"],
        "type": card["type"],
        "title": card.get("title") or "",
        "level": 3,
    }
    cfg = card.get("config") or {}
    if isinstance(cfg, str):
        cfg = json.loads(cfg)
    out["config"] = cfg
    params = _resolve_card_params(cfg, request_params)
    # Substitute declared params in the title too (plain text, not SQL).
    title = out["title"]
    for _name, _value in params.items():
        if _value is not None:
            title = title.replace(f":{_name}", str(_value))
    out["title"] = title

    if card["type"] == "label":
        out["level"] = max(1, min(4, int(cfg.get("level", 3))))
        out["text"] = cfg.get("text", "")
        if cfg.get("value_query"):
            sql = query_engine.substitute_params(cfg["value_query"], params)
            res = query_engine.run_preview(sql, limit=1)
            if res["rows"]:
                out["value"] = _fmt(res["rows"][0][res["columns"][0]], cfg.get("format", "text"))
        if cfg.get("delta_query"):
            sql = query_engine.substitute_params(cfg["delta_query"], params)
            dres = query_engine.run_preview(sql, limit=1)
            if dres["rows"]:
                raw = dres["rows"][0][dres["columns"][0]]
                if raw is not None:
                    out["delta"] = _fmt(raw, cfg.get("delta_format") or cfg.get("format", "text"))
                    out["delta_label"] = cfg.get("delta_label", "")
                    try:
                        num = float(raw)
                    except (TypeError, ValueError):
                        num = None
                    if num is None:
                        out["delta_class"], out["delta_arrow"] = "neutral", ""
                    elif num == 0:
                        out["delta_class"], out["delta_arrow"] = "neutral", "±"
                    else:
                        good_is_down = cfg.get("delta_good", "down") == "down"
                        is_good = (num < 0) if good_is_down else (num > 0)
                        out["delta_class"] = "good" if is_good else "bad"
                        out["delta_arrow"] = "↑" if num > 0 else "↓"
        return out

    if card["type"] == "table":
        if not card.get("query_id"):
            raise ValueError("table card has no query_id")
        sql = query_engine.substitute_params(_query_sql(card["query_id"]), params)
        page_size = max(1, min(int(cfg.get("page_size", config.DEFAULT_PAGE_SIZE)), config.MAX_PAGE_SIZE))
        res = query_engine.run_query(sql, page=page, page_size=page_size)
        links = cfg.get("links") or {}
        # Drill-down links: build the final hrefs server-side (URL-encoded,
        # legacy string or {dashboard, params} dict specs) and attach them
        # per row as row["_links"] = {column: href}.
        if links:
            for r in res["rows"]:
                row_links = {}
                for col, spec in links.items():
                    href = _build_link_href(spec, r, col, params, slug)
                    if href:
                        row_links[col] = href
                r["_links"] = row_links
        out.update(
            columns=res["columns"],
            rows=res["rows"],
            total=res["total"],
            page=res["page"],
            page_size=res["page_size"],
            pages=math.ceil(res["total"] / res["page_size"]) if res["total"] else 1,
            formats=cfg.get("formats", {}),
            hide=set(cfg.get("hide", [])),
            links=links,
        )
        return out

    if card["type"] == "chart":
        option = copy.deepcopy(cfg.get("option"))
        if not option:
            raise ValueError("chart card missing config.option (ECharts option)")
        if cfg.get("data_query") or card.get("query_id"):
            # Live data: run the inline data_query (or the saved query_id)
            # through the query engine (same caps/timeout) at render time
            # and fill option.series[*].data per config.data_map.
            if cfg.get("data_query"):
                sql = cfg["data_query"]
            else:
                sql = _query_sql(card["query_id"])
            sql = query_engine.substitute_params(sql, params)
            res = query_engine.run_preview(sql, limit=config.PREVIEW_LIMIT)
            data_map = cfg.get("data_map")
            if not data_map:
                raise ValueError("chart card with data_query/query_id needs config.data_map")
            option = _apply_chart_data(option, res, data_map)
        # Escape "</" so a "</script>" inside the option JSON cannot break out of the tag.
        out["option_json"] = json.dumps(option).replace("</", "<\\/")
        # Chart click links: config.link = {dashboard?, params: {target_param:
        # value_spec}, exclude?: [values]}. "{x}" is DYNAMIC (the clicked
        # point's x value, ECharts params.name — pie slice name or bar
        # x-label); ":name" resolves to the card's resolved param value;
        # anything else is a static literal. The template wires a click
        # handler that navigates to url + '?' + qs (skipping excluded x
        # values, e.g. a pie's "Other" slice).
        link_cfg = cfg.get("link")
        if isinstance(link_cfg, dict):
            link_params = link_cfg.get("params") or {}
            if isinstance(link_params, dict) and link_params:
                static, dynamic = {}, {}
                for name, value_spec in link_params.items():
                    if isinstance(value_spec, str) and value_spec == "{x}":
                        dynamic[name] = True
                    elif (
                        isinstance(value_spec, str)
                        and value_spec.startswith(":")
                        and value_spec[1:] in params
                    ):
                        static[name] = params[value_spec[1:]]
                    else:
                        static[name] = "" if value_spec is None else str(value_spec)
                target = link_cfg.get("dashboard") or ""
                out["chart_link"] = {
                    "url": f"/d/{target}" if target and target != slug else "?",
                    "static": static,
                    "dynamic": dynamic,
                    "exclude": [str(v) for v in (link_cfg.get("exclude") or [])],
                }
        return out

    raise ValueError(f"unknown card type: {card['type']}")


# --------------------------------------------------------------------------
# pages
# --------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def index():
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT slug, title, description FROM dashboards WHERE is_active = 1 ORDER BY id"
        )
        dashboards = cur.fetchall()
    finally:
        conn.close()
    return jinja.get_template("index.html").render(dashboards=dashboards)


@app.get("/d/{slug}", response_class=HTMLResponse)
def dashboard(slug: str, page: int = 1, request: Request = None):
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM dashboards WHERE slug = %s AND is_active = 1", (slug,))
        dash = cur.fetchone()
        if not dash:
            raise HTTPException(404, "dashboard not found")
        cur.execute(
            """SELECT c.* FROM cards c
               WHERE c.dashboard_id = %s ORDER BY c.position, c.id""",
            (dash["id"],),
        )
        cards = cur.fetchall()
    finally:
        conn.close()

    # Single-param (or any declared-param) substitution: cards declare
    # config.params {name: default}; request query params fill them in
    # (e.g. ?category=Food%20%26%20Dining). Raw values are kept for the
    # pager links so params survive pagination.
    request_params = {k: v for k, v in (request.query_params.items() if request else []) if k != "page"}

    # Param nav (multi-picker drill-down selectors): the dashboard's
    # ``layout`` JSON may declare ``param_nav`` as a single dict (legacy)
    # or a list of {param, label, all_label, query} entries — each becomes
    # one dropdown; the template's onchange/reset preserve the other
    # request params.
    param_nav = _build_param_nav(dash.get("layout"), request_params, slug)

    rendered = []
    for card in cards:
        try:
            rendered.append(_render_card(card, page, request_params, slug))
        except Exception as e:  # surface card errors inline, don't kill the page
            rendered.append(
                {"id": card["id"], "type": "error", "title": card.get("title") or "card", "error": str(e)}
            )
    return jinja.get_template("dashboard.html").render(
        dash=dash, cards=rendered, page=page, fmt=_fmt, params=request_params,
        param_nav=param_nav,
    )


# --------------------------------------------------------------------------
# read-only API (also used by the AI to inspect what's published)
# --------------------------------------------------------------------------

@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "migrations_applied_on_start": app.state.migrations_applied,
    }


@app.get("/api/dashboards")
def api_dashboards():
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT id, slug, title, description, is_active FROM dashboards ORDER BY id")
        return {"dashboards": cur.fetchall()}
    finally:
        conn.close()


@app.get("/api/dashboards/{slug}/cards")
def api_dashboard_cards(slug: str):
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT id, slug FROM dashboards WHERE slug = %s", (slug,))
        dash = cur.fetchone()
        if not dash:
            raise HTTPException(404, "dashboard not found")
        cur.execute(
            """SELECT c.id, c.position, c.type, c.title, c.query_id, c.config,
                      q.name AS query_name
               FROM cards c LEFT JOIN queries q ON q.id = c.query_id
               WHERE c.dashboard_id = %s ORDER BY c.position, c.id""",
            (dash["id"],),
        )
        return {"slug": slug, "cards": cur.fetchall()}
    finally:
        conn.close()


@app.get("/api/queries")
def api_queries():
    conn = _reports_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT id, name, description, sql_text FROM queries ORDER BY id")
        return {"queries": cur.fetchall()}
    finally:
        conn.close()


@app.post("/api/queries/{query_id}/run")
def api_run_query(query_id: int, page: int = 1, page_size: int | None = None, sort: str | None = None):
    """Run a saved query (read-only, paginated)."""
    sql = _query_sql(query_id)
    return query_engine.run_query(sql, page=page, page_size=page_size, order_by=sort)


@app.post("/api/preview")
def api_preview(payload: dict):
    """Ad-hoc SELECT for AI scratch work. Body: {"sql": "SELECT ..."}.

    Same read-only guards as everything else; 500-row cap.
    """
    sql = (payload or {}).get("sql", "")
    if not sql.strip():
        raise HTTPException(400, "body must include 'sql'")
    try:
        return query_engine.run_preview(sql)
    except ValueError as e:
        raise HTTPException(400, str(e))