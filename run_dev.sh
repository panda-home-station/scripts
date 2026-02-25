#!/usr/bin/env bash
set -euo pipefail

# Project directory configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global PID tracking
SERVER_PID=""
WEB_PID=""

# --- Helper Functions ---

# Log messages with colors
log_info() { echo -e "${GREEN}🚀 $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_err() { echo -e "${RED}❌ $1${NC}"; }

# Cleanup on exit or failure
cleanup() {
  local exit_code=$?
  echo ""
  log_warn "Stopping all services and cleaning environment..."
  
  # Kill background processes if they exist
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null || true
  
  # Ensure ports are actually freed
  kill_by_port "${BACKEND_PORT:-8000}"
  kill_by_port 5173
  
  # Cleanup FUSE mounts
  cleanup_fuse_mounts
  
  if [ $exit_code -ne 0 ]; then
    log_err "Exiting due to error (Exit code: $exit_code)"
  else
    log_info "All services closed successfully."
  fi
}

# Mask sensitive info in database URL
mask_db_url() {
  echo "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:****@#'
}

# Kill processes on a given port
kill_by_port() {
  local port="$1"
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  else
    pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ' || true)
  fi

  if [ -n "$pids" ]; then
    log_warn "Port $port is in use, cleaning up process: $pids"
    kill -9 $pids 2>/dev/null || true
  fi
}

# Cleanup FUSE mounts
cleanup_fuse_mounts() {
  # Use current PNAS_STORAGE_PATH or default
  local storage_path="${PNAS_STORAGE_PATH:-$PROJECT_ROOT/fs}"
  local user_mount_dir="$storage_path/vol1/User"

  if [ -d "$user_mount_dir" ]; then
    # Iterate over directories in User mount dir
    for mount_point in "$user_mount_dir"/*; do
      # Check if it exists (even if broken link/mount)
      if [ -e "$mount_point" ]; then
         # Try to unmount quietly. 
         # We use -u (unmount) and -z (lazy) to ensure it detaches even if busy.
         # Redirect stderr to avoid noise if it's not mounted.
         if fusermount -u -z "$mount_point" 2>/dev/null; then
            log_warn "Unmounted stale FUSE mount: $mount_point"
         fi
      fi
    done
  fi
}

# Load environment variables from .env file
load_env_vars() {
  if [ -f .env ]; then
    log_info "Loading environment variables from .env..."
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
}

# --- Main Logic ---

# Register cleanup trap
trap cleanup EXIT INT TERM

# 1. Environment Setup
load_env_vars

BACKEND_PORT="${PNAS_API_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
STATIC_PORT="${PNAS_STATIC_PORT:-8080}"
export PNAS_STATIC_PORT="$STATIC_PORT"

# Database Configuration
if [ -z "${DATABASE_URL:-}" ]; then
  log_err "DATABASE_URL 未设置。请在项目根目录 .env 中或通过环境变量设置 DATABASE_URL 后再运行。"
  exit 1
fi

log_info "Database: $(mask_db_url "$DATABASE_URL")"
if command -v psql >/dev/null 2>&1; then
  if ! psql "$DATABASE_URL" -c 'select 1' -tA >/dev/null 2>&1; then
    log_err "无法连接数据库，请检查 DATABASE_URL 是否正确。"
    exit 1
  fi
fi

# Storage Path (Backend handles sub-directories)
export PNAS_STORAGE_PATH="${PNAS_STORAGE_PATH:-$PROJECT_ROOT/fs}"

log_info "Configuration:"
echo "   Project Root: $PROJECT_ROOT"
echo "   Storage Path:   $PNAS_STORAGE_PATH"
echo "   Backend Port:   $BACKEND_PORT"
echo "   Frontend Port:  $FRONTEND_PORT"
echo "   Static Port:    $STATIC_PORT"

# 2. Pre-flight Cleanup
kill_by_port "$BACKEND_PORT"
kill_by_port "$FRONTEND_PORT"
cleanup_fuse_mounts

# 3. Start Backend (Rust)
log_info "Starting backend service (Rust)..."
pushd nasserver > /dev/null
# Build mode: debug (default) or release via PNAS_BUILD_MODE=release
BUILD_MODE="${PNAS_BUILD_MODE:-debug}"
if [ "${BUILD_MODE}" = "release" ]; then
  BUILD_FLAGS="--release"
  BIN_PATH="target/release/nasserver"
else
  BUILD_FLAGS=""
  BIN_PATH="target/debug/nasserver"
fi

# Always build to ensure changes are picked up (incremental build is fast)
log_info "Building backend binary (${BUILD_MODE})..."
cargo build --bin nasserver ${BUILD_FLAGS}

PNAS_API_PORT="$BACKEND_PORT" \
PNAS_STATIC_PORT="$STATIC_PORT" \
PNAS_STORAGE_PATH="$PNAS_STORAGE_PATH" \
"${BIN_PATH}" &
SERVER_PID=$!
popd > /dev/null

# Quick health check for backend
log_info "Waiting for backend service to be ready (port $BACKEND_PORT)..."
MAX_RETRIES=60
RETRY_COUNT=0
while ! (echo > /dev/tcp/localhost/"$BACKEND_PORT") >/dev/null 2>&1; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log_err "Backend service process crashed!"
    exit 1
  fi
  sleep 1
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    log_err "Timed out waiting for backend service (60s)"
    exit 1
  fi
  if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
    echo "   Still waiting for backend to compile and start..."
  fi
done
log_info "Backend service is ready."

# 4. Start Frontend (React/Vite)
log_info "Starting frontend service (Web Desktop)..."
pushd webdesktop > /dev/null
if [ ! -d "node_modules" ]; then
  log_warn "node_modules not found, installing dependencies..."
  npm install
fi
VITE_PNAS_PORT="$BACKEND_PORT" npm run dev -- --host --port "${FRONTEND_PORT}" &
WEB_PID=$!
popd > /dev/null

# Quick health check for frontend
sleep 2
if ! kill -0 "$WEB_PID" 2>/dev/null; then
  log_err "Frontend service failed to start!"
  exit 1
fi

echo ""
log_info "✅ All services started!"
echo -e "   Backend URL: ${YELLOW}http://localhost:${BACKEND_PORT}${NC}"
echo -e "   Frontend URL: ${YELLOW}http://localhost:${FRONTEND_PORT}${NC}"
echo -e "   ${YELLOW}Hint: Press Ctrl+C to stop${NC}"
echo ""

# Wait for processes. Using wait -n to exit if any background process fails
wait -n
