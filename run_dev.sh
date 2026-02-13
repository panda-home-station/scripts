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
  log_warn "正在停止所有服务并清理环境..."
  
  # Kill background processes if they exist
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null || true
  
  # Ensure ports are actually freed
  kill_by_port "${PNAS_PORT:-8000}"
  kill_by_port 5173
  
  if [ $exit_code -ne 0 ]; then
    log_err "由于错误导致退出 (Exit code: $exit_code)"
  else
    log_info "已成功关闭所有服务。"
  fi
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
    log_warn "端口 $port 被占用，正在清理进程: $pids"
    kill -9 $pids 2>/dev/null || true
  fi
}

# Load environment variables from .env file
load_env_vars() {
  if [ -f .env ]; then
    log_info "正在从 .env 加载环境变量..."
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

BACKEND_PORT="${PNAS_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"

# Database Configuration (PostgreSQL Peer Auth)
if [ -z "${DATABASE_URL:-}" ]; then
  if [ -S "/var/run/postgresql/.s.PGSQL.5432" ]; then
    export DATABASE_URL="postgres:///pnas_db?host=/var/run/postgresql"
  elif [ -S "/tmp/.s.PGSQL.5432" ]; then
    export DATABASE_URL="postgres:///pnas_db?host=/tmp"
  else
    log_warn "未检测到 PostgreSQL Unix Socket，尝试默认连接..."
    export DATABASE_URL="postgres:///pnas_db"
  fi
fi

# Storage Path (Backend handles sub-directories)
export PNAS_DEV_STORAGE_PATH="${PNAS_DEV_STORAGE_PATH:-$PROJECT_ROOT/fs}"

log_info "配置信息:"
echo "   项目根目录: $PROJECT_ROOT"
echo "   存储路径:   $PNAS_DEV_STORAGE_PATH"
echo "   后端端口:   $BACKEND_PORT"
echo "   前端端口:   $FRONTEND_PORT"

# 2. Pre-flight Cleanup
kill_by_port "$BACKEND_PORT"
kill_by_port "$FRONTEND_PORT"

# 3. Start Backend (Rust)
log_info "正在启动后端服务 (Rust)..."
pushd nasserver > /dev/null
PNAS_PORT="$BACKEND_PORT" cargo run --bin server &
SERVER_PID=$!
popd > /dev/null

# Quick health check for backend
log_info "正在等待后端服务就绪 (端口 $BACKEND_PORT)..."
MAX_RETRIES=60
RETRY_COUNT=0
while ! (echo > /dev/tcp/localhost/"$BACKEND_PORT") >/dev/null 2>&1; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log_err "后端服务进程已崩溃！"
    exit 1
  fi
  sleep 1
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    log_err "等待后端服务超时 (60秒)"
    exit 1
  fi
  if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
    echo "   仍在等待后端编译并启动..."
  fi
done
log_info "后端服务已就绪。"

# 4. Start Frontend (React/Vite)
log_info "正在启动前端服务 (Web Desktop)..."
pushd webdesktop > /dev/null
if [ ! -d "node_modules" ]; then
  log_warn "检测到 node_modules 不存在，正在安装依赖..."
  npm install
fi
VITE_PNAS_PORT="$BACKEND_PORT" npm run dev -- --host --port "${FRONTEND_PORT}" &
WEB_PID=$!
popd > /dev/null

# Quick health check for frontend
sleep 2
if ! kill -0 "$WEB_PID" 2>/dev/null; then
  log_err "前端服务启动失败！"
  exit 1
fi

echo ""
log_info "✅ 所有服务已启动！"
echo -e "   后端地址: ${YELLOW}http://localhost:${BACKEND_PORT}${NC}"
echo -e "   前端地址: ${YELLOW}http://localhost:${FRONTEND_PORT}${NC}"
echo -e "   ${YELLOW}提示: 按 Ctrl+C 停止运行${NC}"
echo ""

# Wait for processes. Using wait -n to exit if any background process fails
wait -n
