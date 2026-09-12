import sys
from pathlib import Path

from sqlalchemy import text

BASE_DIR = Path(__file__).resolve().parents[2]
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

from utils.connection import get_postgres_engine

engine = get_postgres_engine()
with engine.connect() as conn:
    result = conn.execute(
        text(
            "SELECT column_name FROM information_schema.columns WHERE table_schema = 'staging' AND table_name = 'inventory';"
        )
    )
    print([r[0] for r in result])
