#!/usr/bin/env bash
# Watches xray-checker's [ERROR] log lines and, for each failure on a proxy
# hosted on this remnanode, pulls the matching connection's lines out of
# remnanode's xray debug log (a plain file inside the container, not
# docker logs) into a single combined report.
#
# remnanode's debug log has no client IP/port, so matching is done by the
# hostname xray-checker actually requests through the proxy (resolved
# automatically from the running containers) plus the xray connection ID,
# within a time window around the failure.
set -euo pipefail

CHECKER_CONTAINER="${CHECKER_CONTAINER:-xray-checker}"
REMNA_CONTAINER="${REMNA_CONTAINER:-remnanode}"
REMNA_LOG_FILE="${REMNA_LOG_FILE:-/var/log/supervisor/xray.out.log}"
REMNA_TAIL_LINES="${REMNA_TAIL_LINES:-200000}" # how far back to scan per event
CHECKER_API_BASE="${CHECKER_API_BASE:-http://127.0.0.1:2112/monitor}"
OUTPUT_FILE="${OUTPUT_FILE:-/var/log/remna-correlated-errors.log}"
# PROXY_TIMEOUT/PROXY_DOWNLOAD_TIMEOUT defaults are 30s/60s, so the real
# request can be well before the moment the failure gets logged.
WINDOW_BEFORE="${WINDOW_BEFORE:-40}" # seconds before the failure to scan
WINDOW_AFTER="${WINDOW_AFTER:-5}"    # seconds after the failure to scan
HOST_FILTER="${HOST_FILTER:-}"       # optional: only correlate if proxy.Server contains this substring/IP

for bin in docker curl jq; do
  command -v "$bin" >/dev/null || { echo "Missing required binary: $bin" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUTPUT_FILE")"

PROXY_CACHE_FILE="$(mktemp)"
PROXY_CACHE_TS=0
trap 'rm -f "$PROXY_CACHE_FILE"' EXIT

refresh_proxy_cache() {
  local now
  now=$(date +%s)
  if (( now - PROXY_CACHE_TS > 60 )) || [[ ! -s "$PROXY_CACHE_FILE" ]]; then
    curl -fsS "$CHECKER_API_BASE/api/v1/proxies" -o "$PROXY_CACHE_FILE" 2>/dev/null \
      && PROXY_CACHE_TS=$now
  fi
}

# Echoes "server" for a given proxy name (empty if not found, or if
# HOST_FILTER is set and the server doesn't match it).
lookup_server() {
  local name="$1"
  refresh_proxy_cache
  jq -r --arg name "$name" --arg hf "$HOST_FILTER" '
    .data[]? | select(.name == $name)
    | select($hf == "" or (.server | contains($hf)))
    | .server
  ' "$PROXY_CACHE_FILE" 2>/dev/null | head -n1
}

# Figures out which hostname xray-checker actually requests through the
# proxy (depends on PROXY_CHECK_METHOD / the matching *_URL env var).
detect_check_host() {
  local method var default url
  method="$(curl -fsS "$CHECKER_API_BASE/api/v1/config" 2>/dev/null | jq -r '.data.checkMethod // "ip"')"
  case "$method" in
    status)   var=PROXY_STATUS_CHECK_URL;   default="http://cp.cloudflare.com/generate_204" ;;
    download) var=PROXY_DOWNLOAD_URL;       default="https://proof.ovh.net/files/1Mb.dat" ;;
    *)        var=PROXY_IP_CHECK_URL;       default="https://api.ipify.org?format=text" ;;
  esac
  url="$(docker inspect "$CHECKER_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^${var}=" | head -n1 | cut -d= -f2-)"
  [[ -z "$url" ]] && url="$default"
  url="${url#*://}"; url="${url%%/*}"; url="${url%%\?*}"; url="${url%%:*}"
  echo "$url"
}

CHECK_HOST="$(detect_check_host)"
echo "Watching ${CHECKER_CONTAINER}; check host through proxy: ${CHECK_HOST:-<unknown>}; correlating with ${REMNA_CONTAINER}:${REMNA_LOG_FILE} -> ${OUTPUT_FILE}"

docker logs -f --since 0s "$CHECKER_CONTAINER" 2>&1 | while IFS= read -r line; do
  [[ "$line" =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ \[ERROR\]\ ([^|]+)\|\ ?(.+)$ ]] || continue
  ts="${BASH_REMATCH[1]}"
  name="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${BASH_REMATCH[2]}")"
  detail="${BASH_REMATCH[3]}"

  server="$(lookup_server "$name")"
  [[ -z "$server" ]] && continue # not a proxy on this remnanode

  ts_epoch="$(date -d "${ts//\//-}" +%s)"
  since_ts="$(date -d "@$((ts_epoch - WINDOW_BEFORE))" +"%Y/%m/%d %H:%M:%S")"
  until_ts="$(date -d "@$((ts_epoch + WINDOW_AFTER))" +"%Y/%m/%d %H:%M:%S")"

  window="$(docker exec "$REMNA_CONTAINER" tail -n "$REMNA_TAIL_LINES" "$REMNA_LOG_FILE" 2>/dev/null \
    | awk -v s="$since_ts" -v e="$until_ts" '{ts=substr($0,1,19); if (ts>=s && ts<=e) print}')"

  {
    echo "===== FAILED ${ts} | ${name} (${server}) | ${detail} ====="
    req_line=""
    if [[ -n "$CHECK_HOST" && -n "$window" ]]; then
      req_line="$(grep -F "received request for" <<<"$window" | grep -F "$CHECK_HOST" | tail -n1 || true)"
    fi
    if [[ -n "$req_line" ]]; then
      conn_id="$(grep -oE '\[[0-9]+\]' <<<"$req_line" | head -n1)"
      echo "--- matched check connection ${conn_id} (host: ${CHECK_HOST}) ---"
      grep -F "$conn_id" <<<"$window"
    else
      echo "--- no request to '${CHECK_HOST:-?}' found in window; raw remnanode lines for ${since_ts}..${until_ts} (may include other clients) ---"
      if [[ -n "$window" ]]; then printf '%s\n' "$window"; else echo "(remnanode log file has nothing in this window — check REMNA_TAIL_LINES / log rotation)"; fi
    fi
    echo
  } >> "$OUTPUT_FILE"

  echo "[correlated] ${ts} ${name} -> ${OUTPUT_FILE}"
done
