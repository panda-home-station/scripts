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
  AGENT_PORT=9000
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

# Start backend and frontend services
start_services() {
  echo "🚀 Starting Services..."

  # 1. Backend (Rust)
  pushd ./nasserver > /dev/null
  echo "   -> Starting NAS Server (Rust)..."
  PNAS_PORT="$BACKEND_PORT" cargo run &
  SERVER_PID=$!
  popd > /dev/null
  
  # 2. Agent Service (Python)
  pushd ./agentservice > /dev/null
  echo "   -> Starting Agent Service..."
  if [ ! -d "venv" ]; then
    python3 -m venv venv
  fi
  source venv/bin/activate
  pip install -r requirements.txt > /dev/null 2>&1
  python3 app/main.py &
  AGENT_PID=$!
  popd > /dev/null
  
  # 3. Frontend (React)
  pushd ./webdesktop > /dev/null
  echo "   -> Starting Web Desktop..."
  npm install > /dev/null 2>&1
  VITE_PNAS_PORT="$BACKEND_PORT" npm run dev -- --host --port "${FRONTEND_PORT}" > /dev/null 2>&1 &
  WEB_PID=$!
  popd > /dev/null
  
  echo ""
  echo "✅ Environment Running!"
  echo "   Backend:       http://localhost:${BACKEND_PORT}"
  echo "   Agent Service: http://localhost:${AGENT_PORT}"
  echo "   Frontend:      http://localhost:${FRONTEND_PORT}"
  echo ""
  
  # Cleanup function
  cleanup() {
    echo ""
    echo "🛑 Shutting down..."
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    kill "$WEB_PID" >/dev/null 2>&1 || true
    kill "$AGENT_PID" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  
  wait
}

main() {
  load_env_vars
  setup_config
  
  # Kill existing processes
  kill_by_port "$BACKEND_PORT"
  kill_by_port "$FRONTEND_PORT"
  kill_by_port "$AGENT_PORT"
  
  # Setup Environment Variables
  export PNAS_DEV_STORAGE_PATH="${PNAS_DEV_STORAGE_PATH:-$(pwd)/fs}"
  export PNAS_VIRTUAL_ROOT_BASE="$PNAS_DEV_STORAGE_PATH/virtual_roots"
  
  echo "🔧 Configuring Environment:"
  echo "   Storage Path: $PNAS_DEV_STORAGE_PATH"
  echo "   Virtual Root: $PNAS_VIRTUAL_ROOT_BASE"
  
  # Note: Directory creation and mapping is now handled by nasserver (Rust) on startup.
  
  start_services
}

main
