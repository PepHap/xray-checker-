#!/usr/bin/env bash
# Watches xray-checker's container logs for [ERROR] (failed check) lines,
# resolves the failing proxy's server:port via the checker's own
# /api/v1/proxies endpoint, then pulls matching lines from remnanode's
# logs around the same timestamp into a single combined report file.
#
# Usage: CHECKER_CONTAINER=xray-checker REMNA_CONTAINER=remnanode \
#        ./remna-fail-correlator.sh
#
# Tunable via env vars (defaults shown):
set -euo pipefail

CHECKER_CONTAINER="${CHECKER_CONTAINER:-xray-checker}"
REMNA_CONTAINER="${REMNA_CONTAINER:-remnanode}"
CHECKER_API_URL="${CHECKER_API_URL:-http://127.0.0.1:2112/monitor/api/v1/proxies}"
OUTPUT_FILE="${OUTPUT_FILE:-/var/log/remna-correlated-errors.log}"
WINDOW_BEFORE="${WINDOW_BEFORE:-15}" # seconds before the failure to include
WINDOW_AFTER="${WINDOW_AFTER:-5}"    # seconds after the failure to include
HOST_FILTER="${HOST_FILTER:-}"       # optional: only correlate if proxy.Server contains this substring/IP

for bin in docker curl jq date; do
  command -v "$bin" >/dev/null || { echo "Missing required binary: $bin" >&2; exit 1; }
done

PROXY_CACHE_FILE="$(mktemp)"
PROXY_CACHE_TS=0
trap 'rm -f "$PROXY_CACHE_FILE"' EXIT

refresh_proxy_cache() {
  local now
  now=$(date +%s)
  if (( now - PROXY_CACHE_TS > 60 )) || [[ ! -s "$PROXY_CACHE_FILE" ]]; then
    if curl -fsS "$CHECKER_API_URL" -o "$PROXY_CACHE_FILE" 2>/dev/null; then
      PROXY_CACHE_TS=$now
    fi
  fi
}

# Echoes "server:port" for a given proxy name, or nothing if not found /
# if HOST_FILTER is set and the server doesn't match it.
lookup_server_port() {
  local name="$1"
  refresh_proxy_cache
  jq -r --arg name "$name" --arg hf "$HOST_FILTER" '
    .data[]? | select(.name == $name)
    | select($hf == "" or (.server | contains($hf)))
    | "\(.server):\(.port)"
  ' "$PROXY_CACHE_FILE" 2>/dev/null | head -n1
}

# Converts a "YYYY/MM/DD HH:MM:SS" checker timestamp + offset (seconds,
# may be negative) into an RFC3339 timestamp docker logs understands.
to_rfc3339() {
  local ts="$1" offset="$2"
  date -d "${ts//\//-} ${offset} seconds" +"%Y-%m-%dT%H:%M:%S"
}

mkdir -p "$(dirname "$OUTPUT_FILE")"
echo "Watching ${CHECKER_CONTAINER}, correlating failures with ${REMNA_CONTAINER} -> ${OUTPUT_FILE}"

docker logs -f --since 0s "$CHECKER_CONTAINER" 2>&1 | while IFS= read -r line; do
  if [[ "$line" =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ \[ERROR\]\ ([^|]+)\|\ ?(.+)$ ]]; then
    ts="${BASH_REMATCH[1]}"
    name="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${BASH_REMATCH[2]}")"
    detail="${BASH_REMATCH[3]}"

    server_port="$(lookup_server_port "$name")"
    [[ -z "$server_port" ]] && continue # not our proxy / on another host

    port="${server_port##*:}"
    since_ts="$(to_rfc3339 "$ts" "-${WINDOW_BEFORE}")"
    until_ts="$(to_rfc3339 "$ts" "+${WINDOW_AFTER}")"

    {
      echo "===== FAILED ${ts} | ${name} (${server_port}) | ${detail} ====="
      echo "--- ${REMNA_CONTAINER} logs, ${since_ts} .. ${until_ts}, matching :${port} ---"
      docker logs --since "$since_ts" --until "$until_ts" "$REMNA_CONTAINER" 2>&1 \
        | grep -F ":${port}" || echo "(нет совпадений по порту в этом окне)"
      echo
    } >> "$OUTPUT_FILE"

    echo "[correlated] ${ts} ${name} -> ${OUTPUT_FILE}"
  fi
done
