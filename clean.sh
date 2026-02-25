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
BACKEND_PORT="${PNAS_API_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"

echo "Cleaning up PNAS development environment..."

# 3. User Confirmation
read -p "⚠️  This will stop all services and delete database pnas_db, are you sure you want to continue? (y/N) " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
  echo "Cleanup operation cancelled."
  exit 0
fi

# 4. Helper Function to Kill Processes by Port
kill_by_port() {
  local port="$1"
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  else
    pids=$(ss -lntp | awk -v p=":${port}" '$4 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ' || true)
  fi

  if [ -n "$pids" ]; then
    echo "Port $port is in use, cleaning up process: $pids"
    kill -9 $pids 2>/dev/null || true
  fi
}

# 4. Clean Backend and Frontend Processes
echo "--- Stopping Processes ---"
kill_by_port "$BACKEND_PORT"
kill_by_port "$FRONTEND_PORT"

# 5. Clean Database
echo "--- Cleaning Database ---"

# Detect Database Connection
DB_NAME="pnas_db"
if [ -z "${DATABASE_URL:-}" ]; then
  if [ -S "/var/run/postgresql/.s.PGSQL.5432" ]; then
    DB_HOST="/var/run/postgresql"
  elif [ -S "/tmp/.s.PGSQL.5432" ]; then
    DB_HOST="/tmp"
  else
    DB_HOST=""
  fi
else
  # Extract host from DATABASE_URL if present (e.g., postgres:///pnas_db?host=/tmp)
  DB_HOST=$(echo "$DATABASE_URL" | sed -n 's/.*host=\([^&]*\).*/\1/p')
  # Extract DB name if present
  extracted_db=$(echo "$DATABASE_URL" | sed -E 's|postgres://[^/]*/([^?]*).*|\1|')
  if [ -n "$extracted_db" ]; then
    DB_NAME="$extracted_db"
  fi
fi

PSQL_OPTS=""
[ -n "$DB_HOST" ] && PSQL_OPTS="$PSQL_OPTS -h $DB_HOST"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql command not found, skipping database cleanup."
else
  echo "Dropping database $DB_NAME..."
  # Connect to 'postgres' database to drop target database
  if psql $PSQL_OPTS -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" 2>/dev/null; then
    echo "Database $DB_NAME dropped successfully."
  else
    echo "Failed to drop database $DB_NAME. It might be in use or you might not have permissions."
    echo "Attempting to force disconnect users and drop..."
    psql $PSQL_OPTS -d postgres -c "
      SELECT pg_terminate_backend(pg_stat_activity.pid)
      FROM pg_stat_activity
      WHERE pg_stat_activity.datname = '$DB_NAME'
        AND pid <> pg_backend_pid();
      DROP DATABASE IF EXISTS \"$DB_NAME\";
    " || echo "Force drop failed."
  fi
fi

echo "Cleanup complete!"
