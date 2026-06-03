# AGENTS.md

## Quick Reference

- **Run locally**: `pip install -r requirements.txt && python main.py`
- **Run via Docker**: `docker compose up -d` (port 12345)
- **No test suite** exists in this repo; no pytest, unittest, or other test runner configured
- **No linter/formatter** configured (no ruff, black, flake8, mypy config)

## Architecture

FastAPI (async) + SQLite/Tortoise ORM backend. Vue 3 frontend lives in a **separate repo** (`vastsa/FileCodeBoxFronted`) and is built into `themes/` during Docker image creation — the `themes/` directory is not in this repo.

```
main.py              # Entry point, creates FastAPI app, mounts routers, runs uvicorn
apps/admin/           # /admin/* routes — dashboard, config, file management, auth
apps/base/            # /share/*, /chunk/*, /presign/* routes — public upload/download
apps/base/models.py   # Tortoise ORM models (FileCodes, UploadChunk, PresignUploadSession, KeyValue)
apps/base/migrations/ # Custom numbered migrations (NOT Alembic)
core/settings.py      # DEFAULT_CONFIG dict + Settings class (runtime mutable)
core/config.py        # Loads/refreshes settings from DB on every request
core/database.py      # DB init, migration runner, startup lock (file-based flock)
core/storage.py       # FileStorageInterface + 5 backends: local, S3, OneDrive, OpenDAL, WebDAV
core/tasks.py         # Background tasks: expire files (10min), clean chunks (1hr)
core/utils.py         # Hashing, token generation, filename sanitization
core/response.py      # Generic APIResponse model
```

## Settings System (non-obvious)

Settings are a two-layer override:
1. `core/settings.py` `DEFAULT_CONFIG` dict provides defaults
2. At runtime, `KeyValue` row with key `"settings"` stores user config as JSON
3. `refresh_settings_middleware` in `main.py` calls `refresh_settings()` on **every request**, reading DB and overlaying onto the `Settings` object

This means: don't edit `DEFAULT_CONFIG` to change a runtime value; change happens via the admin API (`/admin/config/update`). The `Settings` class uses `__getattr__`/`__setattr__` to merge user config over defaults.

## Auth

Custom JWT implementation in `apps/admin/dependencies.py` — uses HMAC-SHA256, **not** PyJWT. Tokens are `base64(header).base64(payload).base64(signature)`.

Password storage: supports both `sha256$salt$hash` format and plaintext fallback (`verify_password` in `core/utils.py`). On startup, `main.py` migrates plaintext admin passwords to hashed format.

Default admin password: `FileCodeBox2023`.

## Storage Backends

Selected by `settings.file_storage` (string: `"local"`, `"s3"`, `"onedrive"`, `"opendal"`, `"webdav"`). All implement `FileStorageInterface` in `core/storage.py`. The `storages` dict maps strings to classes.

Local storage writes to `data/` (`core/settings.py:data_root`). S3/OneDrive/OpenDAL/WebDAV configs are also in `DEFAULT_CONFIG`.

## Database

- SQLite via Tortoise ORM, stored at `data/filecodebox.db`
- WAL mode, 10s busy timeout
- Migrations: custom system in `core/database.py` — scans `apps/*/migrations/migrations_*.py`, tracks in `migrates` table. NOT Alembic.
- Startup uses file-based lock (`data/filecodebox.startup.lock`) for multi-worker safety

## Key Conventions

- API responses use `APIResponse(code, message, detail)` from `core/response.py`
- Admin routes use `Depends(admin_required)` dependency; login (`/admin/login`) is exempted via `ADMIN_PUBLIC_ENDPOINTS`
- Upload routes use `Depends(share_required_login)` — when `openUpload=True`, guests can upload without auth
- IP rate limiting is in-memory (`IPRateLimit` in `apps/base/dependencies.py`) — not shared across workers
- File paths for uploads: `share/data/YYYY/MM/DD/<uuid>/<filename>` under the storage root
- Chunked upload flow: init → upload chunks → complete (with hash verification per chunk)
- Background tasks run as `asyncio.create_task` in the lifespan context, not Celery/etc.

## Docker

The Dockerfile is multi-stage:
1. Stage 1 clones frontend repos from GitHub, **applies patches from `patches/frontend/src/`** over the 2024 theme source, then runs `npm install && npm run build` for both themes
2. Stage 2 copies built themes into `themes/2024` and `themes/2023`

The `patches/frontend/src/` directory mirrors the frontend repo's `src/` structure. When modifying the 2024 theme UI, update files there and re-run the build. The Dockerfile `COPY patches/frontend/ /build/fronted-2024/src/` applies them before `npm run build`.

Environment variables: `HOST` (default `0.0.0.0`), `PORT` (default `12345`), `WORKERS` (default `1`), `LOG_LEVEL` (default `info`). Docker Compose overrides `HOST` to `::` for IPv6 dual-stack.

## Local Frontend Development

The frontend repo must be cloned and built separately — it is NOT in this repo. Steps:

```bash
git clone --depth 1 https://github.com/vastsa/FileCodeBoxFronted.git /tmp/fronted-2024
cd /tmp/fronted-2024
npm install --registry=https://registry.npmmirror.com --maxsockets=1
# Apply patches from this repo
cp /path/to/FileCodeBox/patches/frontend/src/* src/ -r
npm run build
cp -r dist/* /path/to/FileCodeBox/themes/2024/
```

The 2023 theme is similar but uses `--legacy-peer-deps` and targets `themes/2023/`.

Without `themes/` the app crashes at startup (`Directory './themes/2024/assets' does not exist`).

## Gotchas

- `data/` is gitignored and runtime-only; the DB and uploaded files live there. Must be volume-mounted in Docker.
- `themes/` is gitignored — built only during Docker image creation or local dev. Without it, the app crashes.
- The `themesSelect` setting value is like `"themes/2024"`, used as a filesystem path.
- `models.py` uses `pydantic_model_creator` from Tortoise — these are auto-generated Pydantic schemas, not hand-written.
- Config integer fields (`uploadSize`, `openUpload`, etc.) are cast to `int` in `ConfigService.update_config` — passing them as strings from the admin API is fine.
- There is no `.env` file handling; config is all via the DB `KeyValue` table or environment variables for server settings.
- `AlertComponent.vue` uses `z-[100]` (not `z-50`!) — the modal overlay is `z-50`, so alerts must be higher to be visible.
- Upload status flow: `usePresignedUpload` emits `idle → initializing → uploading → confirming → success/error`. The `watch(presignStatus)` in `useSendSubmit` syncs these to `FileUploadArea`. On success, `useSendFlow` holds `uploadStatus='success'` for 1.5s before resetting to `idle`.

## API Quick Test (local dev on port 3333)

```bash
# Upload file (default 1 day expiry)
curl -X POST "http://localhost:3333/share/file/" -F "file=@/path/to/file.txt"

# Upload file with 1 hour expiry
curl -X POST "http://localhost:3333/share/file/" -F "file=@/path/to/file.txt" -F "expire_value=1" -F "expire_style=hour"

# Upload file, expire after 10 downloads
curl -X POST "http://localhost:3333/share/file/" -F "file=@/path/to/file.txt" -F "expire_value=10" -F "expire_style=count"

# Share text
curl -X POST "http://localhost:3333/share/text/" -F "text=hello world"

# Download file by code
curl -L "http://localhost:3333/share/select/?code=CODE" -o filename

# Expire styles: day | hour | minute | count | forever

# Get admin token (default password: FileCodeBox2023)
curl -X POST "http://localhost:3333/admin/login" -H "Content-Type: application/json" -d '{"password": "FileCodeBox2023"}'

# Upload with auth (when guest upload is disabled)
curl -X POST "http://localhost:3333/share/file/" -H "Authorization: Bearer TOKEN" -F "file=@/path/to/file.txt"
```