# Docker — one-command demo

All container assets for the warehouse demo live here. `docker-compose.yml` stays at the **project root** so `docker compose up` works without `-f`.

## Layout

```
docker/
├── Dockerfile               # pipeline image — Python 3.13-slim + uv
├── postgres-init/
│   └── 01_schemas.sql       # creates staging / core / analytics schemas
├── mongo-seed/
│   └── 01_seed.js           # seeds `source` DB (all 23 collections, trimmed)
└── README.md                # this file

../docker-compose.yml        # root compose file (references paths above)
../.dockerignore             # build context ignore list (at root)
```

## Services

| Service    | Image              | Port  | Init logic |
|------------|--------------------|-------|------------|
| `postgres` | `postgres:16-alpine` | 5432 | `docker/postgres-init/01_schemas.sql` → `/docker-entrypoint-initdb.d/` |
| `mongo`    | `mongo:7`            | 27017| `docker/mongo-seed/01_seed.js` → `/docker-entrypoint-initdb.d/` |
| `pipeline` | built from `docker/Dockerfile` | — | `uv sync --frozen && make pipeline` after both DBs healthy |

Health checks: `pg_isready` for Postgres, `mongosh ping` for Mongo. `pipeline` uses `depends_on: condition: service_healthy`.

Environment injected by compose (no `.env` needed for the demo):

```
POSTGRES_HOST=postgres  POSTGRES_DATABASE=data_warehouse
POSTGRES_USER=user      POSTGRES_PASSWORD=password
MONGO_URI=mongodb://mongo:27017  MONGO_DB=source
POSTGRES_SCHEMA_BRONZE=staging  (also POSTGRES_SCHEMA_STAGING)
```

## Usage

```bash
docker compose up --build          # build + run full ELT
docker compose logs -f pipeline    # stream pipeline output
docker compose down                # stop (keep volumes)
docker compose down -v             # stop + wipe seeded data (fresh on next up)

# Ad-hoc
docker compose exec postgres psql -U user -d data_warehouse -c "\dn"
docker compose exec postgres psql -U user -d data_warehouse -c "SELECT * FROM core.dim_customers LIMIT 5;"
docker compose run --rm pipeline uv run ruff check .
docker compose run --rm pipeline uv run pytest tests/python/unit -v
```

## Notes

- **Idempotent**: Postgres/Mongo init scripts run only on first boot (when volumes are empty). Use `down -v` to re-seed.
- **Live updates**: Project root is mounted into `pipeline:/app` so editing `models/*.sql` doesn't require a rebuild; Python deps do (`docker compose build pipeline`).
- **Original bootstrap**: `sql/analytics/00_create_database_and_schemas.sql` (with `CREATE DATABASE` + `\c`) is for manual `psql` use; the container version is `docker/postgres-init/01_schemas.sql` (schemas only) to avoid `CREATE DATABASE` inside `docker-entrypoint-initdb.d`.
- **Ports**: Both DBs are published to the host (`5432`, `27017`) so local `make pipeline` can also hit the container DBs if you point `.env` at `localhost`.
