#!/usr/bin/env bash
# If this script is launched via `sh start.sh`, bash-only syntax will fail.
# Re-exec into bash early so behavior is consistent.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "This script requires bash." >&2
    exit 1
  fi
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

cd "$PROJECT_ROOT"

print_info() { printf '[comfyui2openai] %s\n' "$*"; }
print_warn() { printf '[comfyui2openai] WARN: %s\n' "$*" >&2; }
print_err() { printf '[comfyui2openai] ERROR: %s\n' "$*" >&2; }

trim() {
  local s="$1"
  # shellcheck disable=SC2001
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    local raw_trimmed
    raw_trimmed="$(trim "$line")"
    [[ -z "$raw_trimmed" ]] && continue
    [[ "${raw_trimmed:0:1}" == "#" ]] && continue

    if [[ "$raw_trimmed" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="$(trim "$value")"

      # Strip matching surrounding quotes: "xxx" or 'xxx'
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi

      export "$key=$value"
    fi
  done < "$file"
}

to_bool() {
  # "true/1/yes/on" => true, everything else => false
  local v="${1:-}"
  v="$(echo "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

dir_has_json() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  shopt -s nullglob
  local hits=("$d"/*.json)
  shopt -u nullglob
  [[ ${#hits[@]} -gt 0 ]]
}

# Copy builtin workflows from repo's `ref/*/comfyui-api-workflows/` into
# our local `./comfyui_api_workflows/` so startup doesn't rely on other dirs.
pick_ref_workflows_dir() {
  shopt -s nullglob
  local candidates=("$PROJECT_ROOT"/ref/*/comfyui-api-workflows)
  shopt -u nullglob
  for d in "${candidates[@]}"; do
    if dir_has_json "$d"; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

sync_local_workflows_from_ref() {
  local target="$PROJECT_ROOT/comfyui_api_workflows"
  if dir_has_json "$target"; then
    return 0
  fi

  local src
  src="$(pick_ref_workflows_dir || true)"
  if [[ -z "$src" ]]; then
    return 1
  fi

  shopt -s nullglob
  local jsons=("$src"/*.json)
  shopt -u nullglob
  if [[ ${#jsons[@]} -eq 0 ]]; then
    return 1
  fi

  mkdir -p "$target"
  cp -f "${jsons[@]}" "$target"/
  return 0
}

DEFAULT_WORKFLOWS_CANDIDATES=(
  "$PROJECT_ROOT/comfyui_api_workflows"
  "$PROJECT_ROOT/comfyui_api_workflow"
  "$PROJECT_ROOT/comfyui-api-workflows"
)

# ---- args ----
HOST="${API_LISTEN:-0.0.0.0}"
PORT="${API_PORT:-8000}"
ENV_FILE="${ENV_FILE:-}"
SKIP_COMFY_CHECK=false
CHECK_ONLY=false
RELOAD=false
WORKERS=""
LOG_LEVEL="${UVICORN_LOG_LEVEL:-info}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--listen-host)
      HOST="${2:?missing value for $1}"
      shift 2
      ;;
    --port)
      PORT="${2:?missing value for $1}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?missing value for $1}"
      shift 2
      ;;
    --skip-comfy-check|--no-comfy-check)
      SKIP_COMFY_CHECK=true
      shift 1
      ;;
    --check-only)
      CHECK_ONLY=true
      shift 1
      ;;
    --reload)
      RELOAD=true
      shift 1
      ;;
    --workers)
      WORKERS="${2:?missing value for $1}"
      shift 2
      ;;
    --log-level|--uvicorn-log-level)
      LOG_LEVEL="${2:?missing value for $1}"
      shift 2
      ;;
    --)
      shift 1
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift 1
      ;;
  esac
done

# ---- load env ----
if [[ -z "$ENV_FILE" && -f "$PROJECT_ROOT/.env" ]]; then
  ENV_FILE="$PROJECT_ROOT/.env"
fi
if [[ -n "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
fi

# ---- reasonable defaults for this repo ----
if [[ -z "${INPUT_SUBDIR:-}" ]]; then
  export INPUT_SUBDIR="comfyui2openai"
fi

if [[ -z "${RUNS_DIR:-}" ]]; then
  export RUNS_DIR="$PROJECT_ROOT/runs"
fi

need_select_workflows_dir="false"
if [[ -z "${WORKFLOWS_DIR:-}" ]]; then
  need_select_workflows_dir="true"
elif ! dir_has_json "${WORKFLOWS_DIR:-}"; then
  need_select_workflows_dir="true"
fi

if [[ "$need_select_workflows_dir" == "true" ]]; then
  # Try to populate local workflows first (avoid relying on ref paths).
  sync_local_workflows_from_ref || true

  selected=""
  for candidate in "${DEFAULT_WORKFLOWS_CANDIDATES[@]}"; do
    if dir_has_json "$candidate"; then
      selected="$candidate"
      break
    fi
  done

  if [[ -n "$selected" ]]; then
    export WORKFLOWS_DIR="$selected"
  else
    print_warn "No workflows json found in default candidates; API will start, but workflows endpoints may fail."
  fi
fi

mkdir -p "$RUNS_DIR"

print_info "Project root: $PROJECT_ROOT"
print_info "Listening on: http://$HOST:$PORT"
print_info "WORKFLOWS_DIR: ${WORKFLOWS_DIR:-<unset>}"
print_info "RUNS_DIR: ${RUNS_DIR:-<unset>}"
print_info "INPUT_SUBDIR: ${INPUT_SUBDIR:-<unset>}"
if [[ -n "${ENV_FILE:-}" ]]; then
  print_info "ENV_FILE: $ENV_FILE"
fi

# If user explicitly asked to skip the comfy check, also disable the app-level
# startup check to prevent uvicorn from exiting during lifespan startup.
if [[ "$SKIP_COMFY_CHECK" == "true" && -z "${COMFYUI_STARTUP_CHECK:-}" ]]; then
  export COMFYUI_STARTUP_CHECK="false"
fi

# ---- comfy check ----
COMFYUI_BASE_URL="${COMFYUI_BASE_URL:-http://127.0.0.1:8188}"
COMFYUI_STARTUP_CHECK_RAW="${COMFYUI_STARTUP_CHECK:-true}"
COMFYUI_STARTUP_CHECK="$(to_bool "$COMFYUI_STARTUP_CHECK_RAW")"

if [[ "$SKIP_COMFY_CHECK" == "false" ]]; then
  if ! .venv/bin/python - "$COMFYUI_BASE_URL" <<'PY'
import sys
import asyncio
import httpx

base = sys.argv[1].rstrip("/")
url = base + "/system_stats"

async def main():
    timeout = httpx.Timeout(timeout=5.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        r = await client.get(url, headers={"Accept":"application/json"})
        r.raise_for_status()

asyncio.run(main())
PY
  then
    if [[ "$COMFYUI_STARTUP_CHECK" == "true" ]]; then
      print_err "ComfyUI not reachable at $COMFYUI_BASE_URL (/system_stats). Please check COMFYUI_BASE_URL and network."
      exit 1
    fi
    print_warn "ComfyUI not reachable at $COMFYUI_BASE_URL (/system_stats). API will still start."
  else
    print_info "ComfyUI reachable at $COMFYUI_BASE_URL"
  fi
else
  print_warn "Skip ComfyUI reachability check (via --skip-comfy-check)."
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  print_info "Check only mode finished."
  exit 0
fi

# ---- start ----
if [[ ! -x "$PROJECT_ROOT/.venv/bin/uvicorn" ]]; then
  print_warn "No venv uvicorn found at $PROJECT_ROOT/.venv/bin/uvicorn; falling back to system uvicorn."
  VENV_PYTHON="python3"
  UVICORN_BIN="uvicorn"
else
  VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python"
  UVICORN_BIN="$PROJECT_ROOT/.venv/bin/uvicorn"
fi

UVICORN_CMD=("$UVICORN_BIN" "src.app:app" "--host" "$HOST" "--port" "$PORT" "--log-level" "$LOG_LEVEL")
if [[ "$RELOAD" == "true" ]]; then
  UVICORN_CMD+=("--reload")
fi
if [[ -n "$WORKERS" ]]; then
  UVICORN_CMD+=("--workers" "$WORKERS")
fi
UVICORN_CMD+=("${EXTRA_ARGS[@]}")

print_info "Starting API ..."
exec "${UVICORN_CMD[@]}"