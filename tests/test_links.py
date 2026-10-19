"""Unit tests for the v3.1 drill-down link machinery (server/main.py).

Covers the pure (no-DB) helpers:
  - _link_value      : value_spec -> concrete string ({col} / :name / literal)
  - _build_link_href : table-row link spec -> href (legacy string or dict)
  - _build_param_nav : layout.param_nav (list or legacy dict) -> picker items

Run: python3 tests/test_links.py   (also inside the container:
     docker exec report-hub python3 /app/tests/test_links.py)
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from server import main, query_engine  # noqa: E402


def test_link_value():
    row = {"category": "Food & Dining", "bucket": "Gas"}
    params = {"year": "2024", "category": "Food & Dining"}
    # {col} -> row's value for that column
    assert main._link_value("{category}", row, params) == "Food & Dining"
    assert main._link_value("{bucket}", row, params) == "Gas"
    # :name -> the card's RESOLVED param value
    assert main._link_value(":year", row, params) == "2024"
    # anything else is a literal
    assert main._link_value("2026-10", row, params) == "2026-10"
    # {col} not in the row / :name not declared -> left as literal
    assert main._link_value("{missing}", row, params) == "{missing}"
    assert main._link_value(":missing", row, params) == ":missing"
    # None row value -> empty string (URL-encodes to nothing)
    assert main._link_value("{category}", {"category": None}, params) == ""
    # non-string specs
    assert main._link_value(None, row, params) == ""
    assert main._link_value(5, row, params) == "5"


def test_build_link_href():
    row = {"bucket": "Auto & Transport", "category": "Gas"}
    params = {"year": "2024"}
    # legacy string spec: same dashboard, ?<spec>=<linked column's row value>
    # (urlencode uses '+' for spaces in the query string)
    assert (
        main._build_link_href("category", row, "bucket", params, "categories")
        == "?category=Auto+%26+Transport"
    )
    # dict spec, same dashboard (no `dashboard` key): ?qs
    h = main._build_link_href(
        {"params": {"category": "{bucket}", "year": ":year"}}, row, "bucket", params, "categories"
    )
    assert h == "?category=Auto+%26+Transport&year=2024"
    # dict spec, cross-dashboard: /d/<target>?qs (":category" resolves via
    # the card's resolved params; "2026-10" is a static literal)
    h = main._build_link_href(
        {"dashboard": "transactions", "params": {"category": ":category", "month": "2026-10"}},
        row,
        "category",
        {"year": "2024", "category": "Gas"},
        "categories",
    )
    assert h == "/d/transactions?category=Gas&month=2026-10"
    # dict spec naming the SAME dashboard explicitly -> relative ?qs
    h = main._build_link_href(
        {"dashboard": "categories", "params": {"category": "{bucket}"}}, row, "bucket", params, "categories"
    )
    assert h == "?category=Auto+%26+Transport"
    # unusable specs -> None (template renders a plain cell)
    assert main._build_link_href("", row, "bucket", params, "x") is None
    assert main._build_link_href(None, row, "bucket", params, "x") is None
    assert main._build_link_href({}, row, "bucket", params, "x") is None
    assert main._build_link_href({"params": {}}, row, "bucket", params, "x") is None
    assert main._build_link_href({"dashboard": "x"}, row, "bucket", params, "y") is None


def test_build_param_nav():
    orig = query_engine.run_preview
    calls = []

    def fake_run_preview(sql, limit=500):
        calls.append(sql)
        if "parent_id" in sql:
            return {"columns": ["name"], "rows": [{"name": "A"}, {"name": "B"}]}
        return {"columns": ["y"], "rows": [{"y": "2026"}, {"y": "2025"}]}

    query_engine.run_preview = fake_run_preview
    try:
        layout = {
            "param_nav": [
                {"param": "category", "label": "Category", "query": "SELECT name FROM categories WHERE parent_id = 0"},
                {"param": "year", "label": "Year", "query": "SELECT CAST(YEAR(txn_date) AS CHAR) y FROM transactions GROUP BY y"},
            ]
        }
        # list form: two pickers; `page` excluded from other_params
        items = main._build_param_nav(layout, {"year": "2025", "page": "2"}, "categories")
        assert len(items) == 2
        assert items[0]["param"] == "category"
        assert items[0]["values"] == ["A", "B"]
        assert items[0]["other_params"] == {"year": "2025"}
        assert items[0]["reset_qs"] == "year=2025"
        assert items[1]["current"] == "2025"
        assert items[1]["other_params"] == {}
        assert items[1]["reset_qs"] == ""
        # current value not in the query's list is prepended (leaf drill-downs)
        items = main._build_param_nav(layout, {"category": "Leaf X"}, "categories")
        assert items[0]["values"][0] == "Leaf X"
        # legacy single-dict form still works
        items = main._build_param_nav({"param_nav": {"param": "year", "query": "SELECT 1 y"}}, {}, "yearly")
        assert items and items[0]["param"] == "year"
        # layout may be a JSON string
        items = main._build_param_nav('{"param_nav": {"param": "year", "query": "SELECT 1 y"}}', {}, "yearly")
        assert items and items[0]["param"] == "year"
        # invalid / unusable -> None (template renders no nav)
        assert main._build_param_nav(None, {}, "x") is None
        assert main._build_param_nav("not json", {}, "x") is None
        assert main._build_param_nav({"param_nav": "bogus"}, {}, "x") is None
        assert main._build_param_nav({"param_nav": []}, {}, "x") is None
        assert main._build_param_nav({"param_nav": [{"param": "x"}]}, {}, "x") is None  # no query
        # a failing nav query never kills the page
        def boom(sql, limit=500):
            raise RuntimeError("db down")

        query_engine.run_preview = boom
        assert main._build_param_nav(layout, {}, "x") is None
    finally:
        query_engine.run_preview = orig


if __name__ == "__main__":
    test_link_value()
    test_build_link_href()
    test_build_param_nav()
    print("all link tests passed")