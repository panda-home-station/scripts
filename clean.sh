#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ echo -e "${GREEN}$1${NC}"; }
log_warn(){ echo -e "${YELLOW}$1${NC}"; }
log_err(){ echo -e "${RED}$1${NC}"; }
kill_by_port(){ local port="$1"; local pids=""; if command -v lsof >/dev/null 2>&1; then pids=$(lsof -ti tcp:"$port" 2>/dev/null || true); else pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ' || true); fi; if [ -n "${pids:-}" ]; then log_warn "kill :$port -> $pids"; kill -9 $pids 2>/dev/null || true; fi; }
load_env(){ if [ -f .env ]; then set -a; source .env; set +a; fi; }
cleanup_fuse(){ local storage_path="${PNAS_STORAGE_PATH:-$PROJECT_ROOT/fs}"; local user_dir="$storage_path/vol1/User"; if [ -d "$user_dir" ]; then for m in "$user_dir"/*; do [ -e "$m" ] || continue; fusermount -u -z "$m" 2>/dev/null || true; done; fi; }
rm_rf(){ local p="$1"; if [ -e "$p" ]; then rm -rf "$p"; log_info "removed $p"; fi; }
clear_trash(){ local base="$1"; if [ -d "$base/vol1/User" ]; then find "$base/vol1/User" -maxdepth 2 -type d -name ".Trash" -exec rm -rf {} \; 2>/dev/null || true; log_info "cleared .Trash"; fi; }
mask_db(){ echo "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:****@#'; }
reset_pg(){ local url="$1"; if ! command -v psql >/dev/null 2>&1; then log_warn "psql not found, skip db clean"; return 0; fi; log_info "db: $(mask_db "$url")"; if ! psql "$url" -c 'select 1' -tA >/dev/null 2>&1; then log_err "db unreachable, skip db clean"; return 0; fi; psql "$url" <<'SQL'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN EXECUTE 'DROP SCHEMA storage CASCADE'; END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'sys') THEN EXECUTE 'DROP SCHEMA sys CASCADE'; END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'agent') THEN EXECUTE 'DROP SCHEMA agent CASCADE'; END IF;
END$$;
DROP TABLE IF EXISTS _sqlx_migrations CASCADE;
SQL
log_info "db reset done"; }
ALL=0; DB=0; FORCE=0
for a in "$@"; do case "$a" in --all) ALL=1;; --db) DB=1;; --force|-f) FORCE=1;; esac; done
load_env
BACKEND_PORT="${PNAS_API_PORT:-8000}"; FRONTEND_PORT="${FRONTEND_PORT:-5173}"; STATIC_PORT="${PNAS_STATIC_PORT:-8080}"
kill_by_port "$BACKEND_PORT"; kill_by_port "$FRONTEND_PORT"; kill_by_port "$STATIC_PORT"
cleanup_fuse
rm_rf "$PROJECT_ROOT/nasserver/target"
rm_rf "$PROJECT_ROOT/webdesktop/node_modules"
rm_rf "$PROJECT_ROOT/webdesktop/dist"
rm_rf "$PROJECT_ROOT/webdesktop/.vite"
STORAGE_PATH="${PNAS_STORAGE_PATH:-$PROJECT_ROOT/fs}"
rm_rf "$STORAGE_PATH/vol1/tmp"
rm_rf "$STORAGE_PATH/torrents"
clear_trash "$STORAGE_PATH"
if [ "$ALL" -eq 1 ]; then if [ "$FORCE" -ne 1 ]; then log_warn "delete storage: $STORAGE_PATH"; read -r -p "confirm? [y/N] " ans || true; if [[ "${ans:-}" =~ ^[yY]$ ]]; then rm_rf "$STORAGE_PATH"; else log_warn "skip storage delete"; fi; else rm_rf "$STORAGE_PATH"; fi; fi
if [ "$DB" -eq 1 ]; then if [ -z "${DATABASE_URL:-}" ]; then log_warn "DATABASE_URL empty, skip db clean"; else reset_pg "$DATABASE_URL"; fi; fi
log_info "clean done"
