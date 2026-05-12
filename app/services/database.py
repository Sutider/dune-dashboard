"""Database service - connection pool and query helpers"""

import logging
import time
import psycopg2
import psycopg2.extras
import psycopg2.pool

logger = logging.getLogger(__name__)


class DatabaseService:
    def __init__(self, db_config, min_conn=2, max_conn=10):
        self.db_config = db_config
        self.min_conn = min_conn
        self.max_conn = max_conn
        self.pool = None

    def init_pool(self):
        if self.pool is None:
            # Retry up to 10 times with 2s delays (20s total) to handle startup race conditions
            for attempt in range(10):
                try:
                    self.pool = psycopg2.pool.ThreadedConnectionPool(
                        minconn=self.min_conn,
                        maxconn=self.max_conn,
                        **self.db_config
                    )
                    logger.info("Database connection pool initialized")
                    return self.pool
                except Exception as e:
                    if attempt < 9:
                        logger.warning(f"DB pool attempt {attempt + 1}/10 failed, retrying in 2s: {e}")
                        time.sleep(2)
                    else:
                        logger.error(f"Failed to initialize database pool after 10 attempts: {e}")
                        self.pool = None
        return self.pool

    def get_connection(self):
        try:
            pool = self.init_pool()
            if pool:
                return pool.getconn()
            return psycopg2.connect(**self.db_config)
        except Exception as e:
            logger.error(f"Failed to get database connection: {e}")
            return None

    def return_connection(self, conn):
        if conn and self.pool and hasattr(conn, 'poll'):
            try:
                self.pool.putconn(conn)
            except Exception:
                try:
                    conn.close()
                except Exception:
                    pass

    def close_all(self):
        if self.pool:
            try:
                self.pool.closeall()
            except Exception as e:
                logger.error(f"Error closing pool: {e}")
            self.pool = None

    def query(self, sql, params=None, one=False):
        conn = self.get_connection()
        if not conn:
            return {} if one else []
        cur = None
        try:
            cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(sql, params)
            rows = cur.fetchall()
            if one and rows:
                return rows[0]
            if one:
                return {}
            return rows
        except Exception as e:
            logger.error(f"Database query error: {e}")
            raise
        finally:
            if cur:
                cur.close()
            self.return_connection(conn)

    def execute(self, sql, params=None, commit=True):
        conn = self.get_connection()
        if not conn:
            return False
        cur = None
        try:
            cur = conn.cursor()
            cur.execute(sql, params)
            if commit:
                conn.commit()
            return True
        except Exception as e:
            logger.error(f"Database execute error: {e}")
            if conn:
                conn.rollback()
            return False
        finally:
            if cur:
                cur.close()
            self.return_connection(conn)

    def execute_with_conn(self, conn, sql, params=None):
        cur = conn.cursor()
        try:
            cur.execute(sql, params)
            return cur
        except Exception:
            conn.rollback()
            raise

    def check_health(self):
        try:
            conn = self.get_connection()
            if not conn:
                return False
            cur = conn.cursor()
            cur.execute('SELECT 1')
            cur.fetchone()
            cur.close()
            self.return_connection(conn)
            return True
        except Exception:
            return False

    def ensure_tables(self):
        conn = self.get_connection()
        if not conn:
            return
        cur = None
        try:
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS dune.player_ips (
                    player_id BIGINT PRIMARY KEY,
                    ip_address INET NOT NULL,
                    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
                )
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS dune.bans (
                    id SERIAL PRIMARY KEY,
                    player_id BIGINT UNIQUE,
                    account_id BIGINT,
                    reason TEXT DEFAULT '',
                    note TEXT DEFAULT '',
                    duration INT DEFAULT 0,
                    banned_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    expires_at TIMESTAMP,
                    active BOOLEAN DEFAULT TRUE
                )
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS dune.player_actions (
                    id SERIAL PRIMARY KEY,
                    player_id BIGINT NOT NULL,
                    action_type VARCHAR(50) NOT NULL,
                    reason TEXT DEFAULT '',
                    note TEXT DEFAULT '',
                    duration_minutes INT DEFAULT 0,
                    ip_address INET,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW()
                )
            """)
            conn.commit()
            logger.info("Dashboard tables ensured (player_ips, bans, player_actions)")
        except Exception as e:
            logger.warning(f"Failed to ensure dashboard tables: {e}")
            if conn:
                conn.rollback()
        finally:
            if cur:
                cur.close()
            self.return_connection(conn)
