#!/usr/bin/env bash
set -u

# 1. Load Environment Variables
if [ -f .env ]; then
  # Simple .env parser compatible with bash
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ $line =~ ^# || -z $line ]]; then continue; fi
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)\= ]]; then
      key="${BASH_REMATCH[1]}"
      if [ -z "${!key:-}" ]; then
        export "$line"
      fi
    fi
  done < .env
fi

# 2. Define Variables (Defaults matching run_dev.sh)
BACKEND_PORT="${PNAS_PORT:-8000}"
FRONTEND_PORT=5173

echo "Cleaning up PNAS development environment..."

# 3. Helper Function to Kill Processes by Port
kill_by_port() {
  local port="$1"
  local found=0
  
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids=$(lsof -ti tcp:"$port" || true)
    if [ -n "$pids" ]; then
      echo "Killing processes on port $port: $pids"
      kill -9 $pids || true
      found=1
    fi
  elif command -v fuser >/dev/null 2>&1; then
    if fuser "${port}/tcp" >/dev/null 2>&1; then
      echo "Killing processes on port $port"
      fuser -k "${port}/tcp" || true
      found=1
    fi
  else
    # Fallback using ss/netstat
    local pids
    pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ')
    if [ -n "$pids" ]; then
      echo "Killing processes on port $port: $pids"
      kill -9 $pids || true
      found=1
    fi
  fi
  
  if [ $found -eq 0 ]; then
    echo "No processes found on port $port."
  fi
}

# 4. Clean Backend and Frontend Processes
echo "--- Stopping Processes ---"
kill_by_port "$BACKEND_PORT"
kill_by_port "$FRONTEND_PORT"

# 5. Clean SQLite Database
echo "--- Cleaning SQLite Database ---"

# Clean SQLite database file
DB_FILE="/var/panda/system/db/pnas.db"
if [ -f "$DB_FILE" ]; then
  echo "Removing SQLite database file: $DB_FILE"
  rm -f "$DB_FILE"
  echo "SQLite database file removed."
else
  echo "SQLite database file not found at $DB_FILE"
fi

echo "Cleanup complete!"
