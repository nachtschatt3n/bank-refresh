#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.categorizer"
LOG_FILE="${STATE_DIR}/categorize.log"
STATUS_FILE="${STATE_DIR}/status.json"
PID_FILE="${STATE_DIR}/categorize.pid"

# Find node: prefer mise, fall back to PATH
if command -v mise >/dev/null 2>&1; then
  NODE="$(mise which node 2>/dev/null || command -v node)"
else
  NODE="$(command -v node)"
fi
if [[ -z "$NODE" || ! -x "$NODE" ]]; then
  echo "Error: node not found. Install Node.js or configure mise." >&2
  exit 1
fi
export PATH="$(dirname "$NODE"):${PATH}"

usage() {
  cat <<'EOF'
Usage: run-categorize.sh <command> [options]

Commands:
  start [--rules] [--dry-run]   Start categorization in background
  suggest [--dry-run]           Suggest and create categories from transaction data
  status                        Show current progress
  log                           Tail the log file
  stop                          Stop a running categorization

Options:
  --rules       Create Actual Budget rules for recurring payees after categorizing
  --dry-run     Preview what would happen without making changes

Examples:
  ./run-categorize.sh suggest               # AI suggests categories, creates them
  ./run-categorize.sh start --rules         # Categorize all + create rules
  ./run-categorize.sh start --dry-run       # Preview categorization
  ./run-categorize.sh status                # Check progress
  ./run-categorize.sh log                   # Watch live log
  ./run-categorize.sh stop                  # Stop running job
EOF
  exit 1
}

check_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}

cmd_start() {
  if pid=$(check_running); then
    echo "Already running (PID ${pid}). Use 'stop' first or check 'status'."
    exit 1
  fi

  mkdir -p "$STATE_DIR"
  rm -rf /tmp/actual-categorizer
  mkdir -p /tmp/actual-categorizer

  local extra_args=("$@")

  echo "Starting categorizer..."
  nohup "$NODE" "${SCRIPT_DIR}/categorize-transactions.mjs" "${extra_args[@]}" \
    >> "$LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Started (PID ${pid})"
  echo ""
  echo "Monitor with:"
  echo "  ./run-categorize.sh status"
  echo "  ./run-categorize.sh log"
}

cmd_suggest() {
  mkdir -p "$STATE_DIR"
  rm -rf /tmp/actual-categorizer
  mkdir -p /tmp/actual-categorizer

  local extra_args=("--suggest" "$@")
  echo "Running category suggestion (foreground)..."
  "$NODE" "${SCRIPT_DIR}/categorize-transactions.mjs" "${extra_args[@]}"
}

cmd_status() {
  if pid=$(check_running); then
    echo "Process: running (PID ${pid})"
  else
    echo "Process: not running"
  fi
  echo ""
  "$NODE" "${SCRIPT_DIR}/categorize-transactions.mjs" --status 2>/dev/null || echo "No status data yet."
}

cmd_log() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "No log file yet. Start the categorizer first."
    exit 1
  fi
  echo "=== Last 30 lines (following) ==="
  tail -30f "$LOG_FILE"
}

cmd_stop() {
  if pid=$(check_running); then
    echo "Stopping PID ${pid}..."
    kill "$pid"
    rm -f "$PID_FILE"
    echo "Stopped"
  else
    echo "Not running"
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

cmd="$1"
shift

case "$cmd" in
  start)    cmd_start "$@" ;;
  suggest)  cmd_suggest "$@" ;;
  status)   cmd_status ;;
  log)      cmd_log ;;
  stop)     cmd_stop ;;
  *)        usage ;;
esac
