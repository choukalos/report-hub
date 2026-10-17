import os

# --- MySQL (read-only on finance; owns the reports metadata db) ---
MYSQL_HOST = os.environ.get("MYSQL_HOST", "thor.local")
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_USER = os.environ.get("MYSQL_USER", "dh_reports")
MYSQL_PASSWORD = os.environ.get("MYSQL_PASSWORD", "")
FINANCE_DB = os.environ.get("FINANCE_DB", "finance")
REPORTS_DB = os.environ.get("REPORTS_DB", "reports")

# --- Query engine limits ---
DEFAULT_PAGE_SIZE = 250
MAX_PAGE_SIZE = 1000
PREVIEW_LIMIT = 500
QUERY_TIMEOUT = int(os.environ.get("QUERY_TIMEOUT", "15"))  # seconds