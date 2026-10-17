"""MySQL connection + versioned migration runner (reports metadata db).

Same runner as data-hub, applied to the `reports` database. The report-hub
UI never writes to `reports.*` — this runner is the only writer besides the
AI (direct SQL). Databases are provisioned out-of-band by root
(homelab/data-hub/provision.sh).
"""

import glob
import os
import time

import mysql.connector

from . import config

STARTUP_RETRIES = int(os.environ.get("DB_STARTUP_RETRIES", "30"))
STARTUP_RETRY_DELAY = int(os.environ.get("DB_STARTUP_RETRY_DELAY", "5"))


def get_conn(database=None, user=None, password=None, host=None, port=None):
    return mysql.connector.connect(
        host=host or config.MYSQL_HOST,
        port=port or config.MYSQL_PORT,
        user=user or config.MYSQL_USER,
        password=password or config.MYSQL_PASSWORD,
        database=database,
        autocommit=False,
    )


def connect_with_retry(database=None, **kwargs):
    last_err = None
    for attempt in range(STARTUP_RETRIES):
        try:
            return get_conn(database=database, **kwargs)
        except mysql.connector.Error as e:
            last_err = e
            if attempt < STARTUP_RETRIES - 1:
                time.sleep(STARTUP_RETRY_DELAY)
    raise RuntimeError(
        f"could not connect to MySQL after {STARTUP_RETRIES} attempts: {last_err}. "
        "Is the db provisioned? Run: bash homelab/data-hub/provision.sh"
    )


def apply_migrations(migrations_dir, database, conn=None):
    """Apply unapplied migrations. Returns list of versions applied now."""
    own = conn is None
    if own:
        conn = get_conn(database)
    try:
        cur = conn.cursor()
        cur.execute(
            """CREATE TABLE IF NOT EXISTS schema_migrations (
                 version VARCHAR(64) PRIMARY KEY,
                 applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
               )"""
        )
        conn.commit()
        cur.execute("SELECT version FROM schema_migrations")
        applied = {r[0] for r in cur.fetchall()}

        applied_now = []
        for path in sorted(glob.glob(os.path.join(migrations_dir, "*.sql"))):
            version = os.path.basename(path)
            if version in applied:
                continue
            with open(path) as f:
                sql = f.read()
            for stmt in sql.split(";"):
                stmt = stmt.strip()
                if stmt:
                    cur.execute(stmt)
            cur.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (version,))
            conn.commit()
            applied_now.append(version)
        return applied_now
    finally:
        if own:
            conn.close()