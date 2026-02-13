#!/usr/bin/env bash
set -u

# 1. Load Environment Variables
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# 2. Define Variables
BACKEND_PORT="${PNAS_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"

echo "Cleaning up PNAS development environment..."

# 3. Helper Function to Kill Processes by Port
kill_by_port() {
  local port="$1"
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  else
    pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ' || true)
  fi

  if [ -n "$pids" ]; then
    echo "端口 $port 被占用，正在清理进程: $pids"
    kill -9 $pids 2>/dev/null || true
  fi
}

# 4. Clean Backend and Frontend Processes
echo "--- Stopping Processes ---"
kill_by_port "$BACKEND_PORT"
kill_by_port "$FRONTEND_PORT"

# 5. Clean Database (Optional)
# echo "--- Cleaning Database ---"
# psql -c "DROP DATABASE IF EXISTS pnas_db;"

echo "Cleanup complete!"
