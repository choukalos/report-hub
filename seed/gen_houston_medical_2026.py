#!/usr/bin/env python3
"""Generate seed/v3_houston_medical_2026.sql for report-hub.

Builds the Houston Medical 2026 dashboard (queries + dashboard + cards)
with safe SQL/JSON escaping. Idempotent seed: delete-then-insert per
slug/query name; safe to re-run.
"""
import json
import os

OUT = os.path.join(os.path.dirname(__file__), "v3_houston_medical_2026.sql")

SLUG = "houston-medical-2026"

def q(s: str) -> str:
    """SQL single-quoted literal. Backslashes are doubled so JSON escape
    sequences (\\n etc.) survive MySQL string-literal parsing and the
    stored JSON stays valid."""
    return "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"

def cfg(obj) -> str:
    """JSON config as a SQL literal."""
    return q(json.dumps(obj))

# ---------------------------------------------------------------- queries

GROUP_CASE = """CASE
      WHEN t.description LIKE '%AIRBNB%' OR (t.description LIKE '%MARRIOTT%' AND t.description LIKE '%HOUSTON%') THEN 'Lodging (Airbnb / Marriott)'
      WHEN t.description LIKE '%MYCHART%' OR t.description LIKE '%MDACC PHARMACY%' THEN 'Medical (MD Anderson)'
      WHEN t.payee LIKE '%Harris County Toll%' OR t.payee IN ('Shell', 'Phillips 66') OR c.name = 'Gas' OR (c.name = 'Auto & Transport' AND t.description REGEXP 'GAS/CARWASH') THEN 'Gas & tolls'
      WHEN c.name IN ('Restaurants', 'Fast Food', 'Coffee Shops', 'Food & Dining', 'Alcohol & Bars') THEN 'Dining out'
      WHEN c.name = 'Groceries' THEN 'Groceries'
      WHEN c.name = 'Parking' OR t.description LIKE '%MAYS GARAG%' THEN 'Parking'
      ELSE 'Other (Houston metro)'
    END"""

GROUP_ORDER = """FIELD(grp, 'Lodging (Airbnb / Marriott)', 'Medical (MD Anderson)', 'Gas & tolls', 'Dining out', 'Groceries', 'Parking', 'Other (Houston metro)')"""

JOIN_TRIP = """JOIN trip_transactions tt ON tt.transaction_id = t.id
JOIN trips tr ON tr.id = tt.trip_id AND tr.slug = 'houston-medical-2026'"""

QUERIES = {
    "hou_trip_total": (
        f"SELECT COALESCE(SUM(-t.amount_cents), 0)\n"
        f"FROM transactions t\n{JOIN_TRIP}\n"
        f"WHERE t.amount_cents < 0",
        "Total Houston Medical 2026 trip spend (cents), all tagged transactions",
    ),
    "hou_trip_total_stay": (
        f"SELECT COALESCE(SUM(-t.amount_cents), 0)\n"
        f"FROM transactions t\n{JOIN_TRIP}\n"
        f"WHERE t.amount_cents < 0\n"
        f"  AND NOT (t.description LIKE '%MYCHART%' OR t.description LIKE '%MDACC PHARMACY%')",
        "Trip spend (cents) excluding MD Anderson medical bills",
    ),
    "hou_trip_total_medical": (
        f"SELECT COALESCE(SUM(-t.amount_cents), 0)\n"
        f"FROM transactions t\n{JOIN_TRIP}\n"
        f"WHERE t.amount_cents < 0\n"
        f"  AND (t.description LIKE '%MYCHART%' OR t.description LIKE '%MDACC PHARMACY%')",
        "MD Anderson medical spend (cents): MyChart bills + MDACC pharmacy",
    ),
    "hou_trip_txn_count": (
        f"SELECT COUNT(*)\n"
        f"FROM transactions t\n{JOIN_TRIP}\n"
        f"WHERE t.amount_cents < 0",
        "Count of tagged Houston Medical 2026 transactions",
    ),
    "hou_trip_group_totals": (
        f"SELECT grp, COUNT(*) txn_count, SUM(cents) total_cents\n"
        f"FROM (\n"
        f"  SELECT {GROUP_CASE} grp, -t.amount_cents cents\n"
        f"  FROM transactions t\n"
        f"  LEFT JOIN categories c ON c.id = t.category_id\n"
        f"  {JOIN_TRIP}\n"
        f"  WHERE t.amount_cents < 0\n"
        f") g\n"
        f"GROUP BY grp\nORDER BY {GROUP_ORDER}",
        "Tagged trip spend grouped (lodging / medical / gas / dining / groceries / parking / other)",
    ),
    "hou_trip_monthly": (
        "WITH RECURSIVE months AS (\n"
        "  SELECT '2026-07-01' mstart, 1 n\n"
        "  UNION ALL\n"
        "  SELECT DATE_ADD(mstart, INTERVAL 1 MONTH), n + 1\n"
        "  FROM months WHERE n < 6\n"
        "),\n"
        "tagged AS (\n"
        "  SELECT t.txn_date, -t.amount_cents cents,\n"
        "         (t.description LIKE '%MYCHART%' OR t.description LIKE '%MDACC PHARMACY%') is_med\n"
        f"  FROM transactions t\n{JOIN_TRIP}\n"
        "  WHERE t.amount_cents < 0\n"
        ")\n"
        "SELECT DATE_FORMAT(mo.mstart, '%Y-%m') ym, 'Stay & travel' label,\n"
        "       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 0 THEN tg.cents END), 0) / 100, 2) amount\n"
        "FROM months mo\n"
        "LEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\n"
        "GROUP BY mo.mstart\n"
        "UNION ALL\n"
        "SELECT DATE_FORMAT(mo.mstart, '%Y-%m') ym, 'Medical (MD Anderson)' label,\n"
        "       ROUND(COALESCE(SUM(CASE WHEN tg.is_med = 1 THEN tg.cents END), 0) / 100, 2) amount\n"
        "FROM months mo\n"
        "LEFT JOIN tagged tg ON tg.txn_date >= mo.mstart AND tg.txn_date < DATE_ADD(mo.mstart, INTERVAL 1 MONTH)\n"
        "GROUP BY mo.mstart\n"
        "ORDER BY FIELD(label, 'Stay & travel', 'Medical (MD Anderson)'), ym",
        "Monthly tagged trip spend Jul-Dec 2026, dollars, stay/travel vs medical series",
    ),
    "hou_trip_pie": (
        f"SELECT grp, ROUND(SUM(cents) / 100, 2) amount\n"
        f"FROM (\n"
        f"  SELECT {GROUP_CASE} grp, -t.amount_cents cents\n"
        f"  FROM transactions t\n"
        f"  LEFT JOIN categories c ON c.id = t.category_id\n"
        f"  {JOIN_TRIP}\n"
        f"  WHERE t.amount_cents < 0\n"
        f") g\n"
        f"GROUP BY grp\nORDER BY {GROUP_ORDER}",
        "Tagged trip spend by group, dollars (pie)",
    ),
    "hou_trip_txns": (
        f"SELECT t.txn_date date, t.payee, t.description,\n"
        f"       {GROUP_CASE} group_name,\n"
        f"       tt.tag_reason,\n"
        f"       -t.amount_cents amount\n"
        f"FROM transactions t\n"
        f"LEFT JOIN categories c ON c.id = t.category_id\n"
        f"{JOIN_TRIP}\n"
        f"WHERE t.amount_cents < 0\n"
        f"ORDER BY t.txn_date DESC, t.id DESC",
        "All tagged Houston Medical 2026 transactions (newest first)",
    ),
    "hou_trip_excluded": (
        "SELECT t.txn_date date, t.payee, t.description,\n"
        "       CASE\n"
        "         WHEN t.payee IN ('Allegiant Airlines', 'Delta Airlines', 'Delta') THEN 'Flight (not part of trip - confirmed 2026-11-23)'\n"
        "         WHEN t.description LIKE 'HEB CURBSIDE 800-432-3113%' THEN 'H-E-B curbside (normal weekend/Bella groceries - not trip, confirmed 2026-11-23)'\n"
        "         WHEN t.description LIKE '%MD Anderson bills%' THEN 'MD Anderson funding transfer (not spend)'\n"
        "       END note,\n"
        "       -t.amount_cents amount\n"
        "FROM transactions t\n"
        "LEFT JOIN categories c ON c.id = t.category_id\n"
        "WHERE t.txn_date BETWEEN '2026-07-15' AND '2026-12-31'\n"
        "  AND t.amount_cents < 0\n"
        "  AND (\n"
        "        t.payee IN ('Allegiant Airlines', 'Delta Airlines', 'Delta')\n"
        "     OR (t.description LIKE 'HEB CURBSIDE 800-432-3113%' AND t.txn_date >= '2026-10-01')\n"
        "     OR (t.description LIKE '%MD Anderson bills%' AND c.bucket = 'Transfer')\n"
        "  )\n"
        "  AND NOT EXISTS (SELECT 1 FROM trip_transactions tt WHERE tt.transaction_id = t.id)\n"
        "ORDER BY t.txn_date",
        "Excluded trip-window items (flights, curbside groceries, MD Anderson funding transfer) - confirmed not trip spend 2026-11-23",
    ),
}

# ---------------------------------------------------------------- cards

NOTES_TEXT = (
    "Window 2026-07-15 to 2026-12-17 (final audiology follow-up). Tagged = spend (debits) matching any rule: "
    "Houston-metro merchant location (Houston, Katy, La Grange, Cypress, Brookshire + other metro cities), "
    "MD Anderson payees (MDACC / MyChart / pharmacy), Airbnb, Harris County EZ-Tag tolls, "
    "Buc-ee's/Shell gas & food stops (any store/location - I-10 corridor included). "
    "Flights (Allegiant/Delta) and HEB curbside are normal spend, not trip (chuck 2026-11-23). "
    "Home (Round Rock/Austin) spending stays out. Airbnb: two bookings Oct 25 - Nov 7 and Nov 8 - Dec 11 "
    "(~$11k total per the family; the dog held the Saturday checkout). Bill 1 ($8,622.18, charged Oct 20) is in the data; "
    "bill 2 lands in the next export. Data through 2026-11-13 - re-run scripts/trips/tag_houston_medical_2026.sql "
    "(data-hub repo) after each ingest to pick up new rows."
)

DASH_DESC = (
    "Expenses tagged to the 2026 Houston medical stay (MD Anderson treatment; home base Round Rock, TX), kept "
    "separate from normal spending. Data through 2026-11-13 - re-run the tag script after each ingest. Rules: see notes card."
)

monthly_option = {
    "tooltip": {"trigger": "axis"},
    "legend": {"data": ["Stay & travel", "Medical (MD Anderson)"]},
    "grid": {"left": 70, "right": 20, "top": 40, "bottom": 55},
    "xAxis": {"type": "category", "axisLabel": {"rotate": 45}},
    "yAxis": {"type": "value", "axisLabel": {"formatter": "${value}"}},
    "series": [
        {"name": "Stay & travel", "type": "bar", "stack": "trip", "itemStyle": {"color": "#4f8ef7"}, "data": []},
        {"name": "Medical (MD Anderson)", "type": "bar", "stack": "trip", "itemStyle": {"color": "#f76f6f"}, "data": []},
    ],
}

pie_option = {
    "tooltip": {"trigger": "item"},
    "legend": {"orient": "vertical", "left": "left", "top": "middle"},
    "series": [
        {"name": "Spend", "type": "pie", "radius": ["28%", "62%"], "center": ["62%", "50%"], "data": []}
    ],
}

CARDS = [
    (1, "label", "Total - trip & stay (all tagged spend)", None,
     {"level": 2, "value_query": QUERIES["hou_trip_total"][0], "format": "currency"}),
    (2, "label", "Stay & travel (excl. medical bills)", None,
     {"level": 2, "value_query": QUERIES["hou_trip_total_stay"][0], "format": "currency"}),
    (3, "label", "Medical (MD Anderson bills + pharmacy)", None,
     {"level": 2, "value_query": QUERIES["hou_trip_total_medical"][0], "format": "currency"}),
    (4, "label", "Tagged transactions", None,
     {"level": 2, "value_query": QUERIES["hou_trip_txn_count"][0], "format": "number"}),
    (5, "label", "How this is tagged", None,
     {"level": 3, "text": NOTES_TEXT}),
    (6, "table", "Spend by group", "hou_trip_group_totals",
     {"formats": {"total_cents": "currency", "txn_count": "number"}, "page_size": 250}),
    (7, "chart", "Monthly trip spend (Jul - Dec 2026)", "hou_trip_monthly",
     {"data_query": QUERIES["hou_trip_monthly"][0],
      "data_map": {"x": "ym", "value": "amount", "series": "label"},
      "option": monthly_option}),
    (8, "chart", "Group mix", "hou_trip_pie",
     {"data_query": QUERIES["hou_trip_pie"][0],
      "data_map": {"x": "grp", "value": "amount"},
      "option": pie_option}),
    (9, "table", "All tagged transactions", "hou_trip_txns",
     {"formats": {"date": "date", "amount": "currency"}, "page_size": 250}),
    (10, "table", "Excluded - not trip spend (review)", "hou_trip_excluded",
     {"formats": {"date": "date", "amount": "currency"}, "page_size": 250}),
]

# ---------------------------------------------------------------- emit

# column limits (reports schema): description VARCHAR(255)
assert len(DASH_DESC) <= 255, f"DASH_DESC too long: {len(DASH_DESC)}"
for _n, (_s, _d) in QUERIES.items():
    assert len(_d) <= 255, f"query description too long ({len(_d)}): {_n}"

lines = []
lines.append("-- ============================================================")
lines.append("-- Houston Medical 2026 dashboard seed (report-hub)")
lines.append("--")
lines.append("-- Seeds the houston-medical-2026 dashboard into the `reports`")
lines.append("-- database: saved queries (hou_*), the dashboard row, and 10")
lines.append("-- cards (4 KPI labels, notes, group table, monthly chart, pie,")
lines.append("-- all-tagged-transactions table, excluded/ambiguous table).")
lines.append("--")
lines.append("-- Data plane: finance.trips + finance.trip_transactions")
lines.append("-- (data-hub migration 0003_trips.sql); tagging rules live in")
lines.append("-- data-hub scripts/trips/tag_houston_medical_2026.sql (re-run")
lines.append("-- after each bank ingest; idempotent).")
lines.append("--")
lines.append("-- IDEMPOTENT: delete-then-insert per slug/query name; safe to")
lines.append("-- re-run. Apply manually as dh_reports (NOT via the migration")
lines.append("-- runner):")
lines.append("--   mysql -h <mysql-host> -u dh_reports -p reports < seed/v3_houston_medical_2026.sql")
lines.append("--")
lines.append("-- Conventions: spend = SUM of negative (debit) amounts shown as")
lines.append("-- positive; tables present integer cents via the \"currency\"")
lines.append("-- format; chart values are dollars (divided by 100 in SQL).")
lines.append("-- ============================================================")
lines.append("")
lines.append(f"DELETE FROM dashboards WHERE slug = {q(SLUG)};")
lines.append(f"DELETE FROM queries WHERE name IN ({', '.join(q(n) for n in QUERIES)});")
lines.append("")
lines.append("-- 1) saved queries")
for name, (sql, desc) in QUERIES.items():
    lines.append(f"INSERT INTO queries (name, sql_text, params, description) VALUES ({q(name)}, {q(sql)}, NULL, {q(desc)});")
lines.append("")
lines.append("-- 2) dashboard")
lines.append(f"INSERT INTO dashboards (slug, title, description, section, sort_order, is_active) VALUES ({q(SLUG)}, {q('Houston Medical 2026')}, {q(DASH_DESC)}, {q('finance')}, 80, 1);")
lines.append("")
lines.append("-- 3) cards")
vals = []
for pos, ctype, title, query_name, config in CARDS:
    qid = f"(SELECT id FROM queries WHERE name = {q(query_name)})" if query_name else "NULL"
    vals.append(
        f"  ((SELECT id FROM dashboards WHERE slug = {q(SLUG)}), {pos}, {q(ctype)}, {q(title)}, {qid}, {cfg(config)})"
    )
lines.append("INSERT INTO cards (dashboard_id, position, type, title, query_id, config)")
lines.append("VALUES")
lines.append(",\n".join(vals) + ";")
lines.append("")

with open(OUT, "w") as f:
    f.write("\n".join(lines))
print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")
