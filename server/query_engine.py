"""Read-only query engine.

Enforces the read-only contract:
  - single SELECT/WITH statements only (no multi-statement, no DDL/DML)
  - no INTO OUTFILE/INFILE, LOAD_FILE, SLEEP, BENCHMARK, or system schemas
  - no locking reads (FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE)
  - statement timeout (MAX_EXECUTION_TIME)
  - hard row caps (250/page default, 1000 max; 500 for preview)

All card queries are AI-authored and stored in reports.queries; nothing is
free-typed by end users. The MySQL user itself is read-only on finance.*.
"""

import re

import mysql.connector

from . import config

_ALLOWED_START = re.compile(r"^\s*(select|with)\b", re.I)
_FORBIDDEN = re.compile(
    r"\b(into\s+(out|in)file|load_file\s*\(|sleep\s*\(|benchmark\s*\()"
    r"|(information_schema|performance_schema|mysql\.|sys\.)"
    r"|\bfor\s+(update|share)\b"
    r"|\block\s+in\s+share\s+mode\b",
    re.I,
)
_MULTI_STATEMENT = re.compile(r";\s*\S")
_IDENT = re.compile(r"^[A-Za-z0-9_]+$")


_PLACEHOLDER = re.compile(r":([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])")


def substitute_params(sql: str, values: dict) -> str:
    """Substitute declared ``:name`` placeholders with escaped string literals.

    Only names present in ``values`` are substituted; every other
    ``:placeholder`` is left untouched (it will then fail validation or
    execution rather than be injected). Values are escaped (backslashes
    doubled, single quotes doubled) so they cannot break out of their
    literal — there is no raw string interpolation of request input.

    Callers must resolve every declared param to a concrete value (request
    value or its default) before calling, so no declared placeholder is
    left raw in the SQL.
    """
    def _repl(m):
        name = m.group(1)
        if name not in values or values[name] is None:
            return m.group(0)
        v = str(values[name])
        return "'" + v.replace("\\", "\\\\").replace("'", "''") + "'"

    return _PLACEHOLDER.sub(_repl, sql)


def validate_select(sql: str) -> str:
    s = sql.strip()
    if s.endswith(";"):
        s = s[:-1].rstrip()
    if _MULTI_STATEMENT.search(s):
        raise ValueError("multi-statement queries are not allowed")
    if not _ALLOWED_START.match(s):
        raise ValueError("only SELECT/WITH queries are allowed")
    if _FORBIDDEN.search(s):
        raise ValueError("query contains a forbidden construct")
    return s


def _connect():
    conn = mysql.connector.connect(
        host=config.MYSQL_HOST,
        port=config.MYSQL_PORT,
        user=config.MYSQL_USER,
        password=config.MYSQL_PASSWORD,
        database=config.FINANCE_DB,
        connection_timeout=config.QUERY_TIMEOUT,
        read_timeout=config.QUERY_TIMEOUT + 5,
    )
    cur = conn.cursor()
    cur.execute(f"SET SESSION MAX_EXECUTION_TIME = {config.QUERY_TIMEOUT * 1000}")
    conn.commit()
    return conn


def run_query(sql: str, page: int = 1, page_size: int | None = None, order_by: str | None = None):
    """Run a validated SELECT against finance with pagination.

    Returns {"columns", "rows", "total", "page", "page_size"}.
    """
    base = validate_select(sql)
    page_size = min(page_size or config.DEFAULT_PAGE_SIZE, config.MAX_PAGE_SIZE)
    page = max(1, page)

    conn = _connect()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(f"SELECT COUNT(*) AS c FROM ({base}) AS _t")
        total = cur.fetchone()["c"]

        outer_order = ""
        if order_by:
            col, _, direction = order_by.partition(" ")
            if _IDENT.match(col) and direction.upper() in ("ASC", "DESC"):
                outer_order = f" ORDER BY `{col}` {direction.upper()}"

        cur.execute(
            f"SELECT * FROM ({base}) AS _t{outer_order} LIMIT %s OFFSET %s",
            (page_size, (page - 1) * page_size),
        )
        rows = cur.fetchall()
        columns = [d[0] for d in cur.description]
        return {
            "columns": columns,
            "rows": rows,
            "total": total,
            "page": page,
            "page_size": page_size,
        }
    finally:
        conn.close()


def run_preview(sql: str, limit: int = config.PREVIEW_LIMIT):
    """Ad-hoc SELECT for AI scratch work (same guards, small cap)."""
    base = validate_select(sql)
    conn = _connect()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(f"SELECT * FROM ({base}) AS _t LIMIT %s", (min(limit, config.PREVIEW_LIMIT),))
        rows = cur.fetchall()
        columns = [d[0] for d in cur.description]
        return {"columns": columns, "rows": rows}
    finally:
        conn.close()