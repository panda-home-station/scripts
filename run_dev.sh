#!/usr/bin/env bash
set -euo pipefail

# Load environment variables from .env file
load_env_vars() {
  if [ -f .env ]; then
    while IFS= read -r line; do
      line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      if [[ $line =~ ^# || -z $line ]]; then continue; fi
      if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)\= ]]; then
        key="${BASH_REMATCH[1]}"
        value="${line#*=}"
        if [ -z "${!key:-}" ]; then
          export "$line"
        fi
      fi
    done < .env
  fi
}

# Setup configuration variables
setup_config() {
  BACKEND_PORT="${PNAS_PORT:-8000}"
  FRONTEND_PORT=5173
}

# Kill processes on a given port
kill_by_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids=$(lsof -ti tcp:"$port" || true)
    if [ -n "$pids" ]; then
      kill -9 $pids || true
    fi
  elif command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" || true
  else
    local pids
    pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ')
    if [ -n "$pids" ]; then
      kill -9 $pids || true
    fi
  fi
}

# Check if a port is open on a host
is_port_open() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -nP | grep -q ":$port"
    return $?
  fi
  timeout 1 bash -c ">/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

# Check if a port is in use
port_in_use() {
  local port="$1"
  ss -lntp | awk -v p=":${port}" '$4 ~ p {f=1} END {exit f?0:1}'
}



# Start backend and frontend services
start_services() {
  pushd ./nasserver
  PNAS_PORT="$BACKEND_PORT" cargo run &
  SERVER_PID=$!
  popd
  
  pushd ./webdesktop
  npm install
  VITE_PNAS_PORT="$BACKEND_PORT" npm run dev -- --host --port "${FRONTEND_PORT}" &
  WEB_PID=$!
  echo "Backend: http://localhost:${BACKEND_PORT}"
  echo "Frontend: http://localhost:${FRONTEND_PORT}"
  popd
  
  # Cleanup function to kill background processes
  cleanup() {
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    kill "$WEB_PID" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  
  # Wait for background processes
  wait
}

# Main function to orchestrate the dev environment setup
main() {
  load_env_vars
  setup_config
  
  # Kill processes on backend and frontend ports
  kill_by_port "$BACKEND_PORT"
  kill_by_port "$FRONTEND_PORT"
  
  # Setup additional environment variables
  export JWT_SECRET="${JWT_SECRET:-dev-secret}"
  export PNAS_DEV_STORAGE_PATH="${PNAS_DEV_STORAGE_PATH:-/var/panda/system}"
  mkdir -p "$PNAS_DEV_STORAGE_PATH"
  mkdir -p "$PNAS_DEV_STORAGE_PATH/vol1"
  mkdir -p "$PNAS_DEV_STORAGE_PATH/db"
  touch "$PNAS_DEV_STORAGE_PATH/db/pnas.db"
  chmod 600 "$PNAS_DEV_STORAGE_PATH/db/pnas.db"
  
  start_services
}

# Run the main function
main
