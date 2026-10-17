import json
import math
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
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


def _render_card(card: dict, page: int) -> dict:
    """Render one card into template-ready data (query + config -> payload)."""
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

    if card["type"] == "label":
        out["level"] = int(cfg.get("level", 3))
        out["text"] = cfg.get("text", "")
        if cfg.get("value_query"):
            res = query_engine.run_preview(cfg["value_query"], limit=1)
            if res["rows"]:
                out["value"] = _fmt(res["rows"][0][res["columns"][0]], cfg.get("format", "text"))
        return out

    if not card.get("query_id"):
        raise ValueError("card has no query_id")
    sql = _query_sql(card["query_id"])

    if card["type"] == "table":
        page_size = min(int(cfg.get("page_size", config.DEFAULT_PAGE_SIZE)), config.MAX_PAGE_SIZE)
        res = query_engine.run_query(sql, page=page, page_size=page_size)
        out.update(
            columns=res["columns"],
            rows=res["rows"],
            total=res["total"],
            page=res["page"],
            page_size=res["page_size"],
            pages=math.ceil(res["total"] / res["page_size"]) if res["total"] else 1,
            formats=cfg.get("formats", {}),
            hide=set(cfg.get("hide", [])),
        )
        return out

    if card["type"] == "chart":
        option = cfg.get("option")
        if not option:
            raise ValueError("chart card missing config.option (ECharts option)")
        out["option_json"] = json.dumps(option)
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
def dashboard(slug: str, page: int = 1):
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

    rendered = []
    for card in cards:
        try:
            rendered.append(_render_card(card, page))
        except Exception as e:  # surface card errors inline, don't kill the page
            rendered.append(
                {"id": card["id"], "type": "error", "title": card.get("title") or "card", "error": str(e)}
            )
    return jinja.get_template("dashboard.html").render(
        dash=dash, cards=rendered, page=page, fmt=_fmt
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