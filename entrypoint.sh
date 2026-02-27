#!/bin/sh
# ---------------------------------------------------------------------------
# SNI Router — entrypoint
# Generates /usr/local/etc/haproxy/haproxy.cfg from environment variables,
# validates it, then hands off to haproxy.
#
# Environment variables
# ---------------------
#  SNI_LISTEN_PORT=443           Port to listen on for TLS/SNI routing (default: 443)
#  SNI_ROUTE_N=hostname:ip:port  TLS SNI routing rules, N = 1, 2, 3 …
#                                  Wildcard: *.example.com matches any subdomain
#  SNI_DEFAULT=ip:port           Default backend when no SNI rule matches (REQUIRED)
#  TCP_ROUTE_N=lport:ip:dport    Plain TCP port-based routing rules, N = 1, 2, 3 …
#  PROXY_PROTOCOL=true           Forward PROXY protocol v2 header to backends
#                                  so that upstream services see the real client IP
#  STATS_ENABLED=true            Enable HAProxy built-in stats web UI (default: false)
#  STATS_PORT=8404               Port for the stats UI (default: 8404)
#  STATS_PASSWORD=secret         Password for the stats UI — user is always "admin"
#                                  Leave empty to disable authentication
# ---------------------------------------------------------------------------
set -e

CFG=/usr/local/etc/haproxy/haproxy.cfg
LISTEN_PORT="${SNI_LISTEN_PORT:-443}"
PROXY_PROTO="${PROXY_PROTOCOL:-false}"
STATS_ENABLED="${STATS_ENABLED:-false}"
STATS_PORT="${STATS_PORT:-8404}"
STATS_PASSWORD="${STATS_PASSWORD:-}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
server_opts() {
  [ "$PROXY_PROTO" = "true" ] && echo "send-proxy-v2" || echo ""
}

# --------------------------------------------------------------------------
# Mandatory: SNI_DEFAULT
# --------------------------------------------------------------------------
if [ -z "${SNI_DEFAULT:-}" ]; then
  echo "[sni-router] ERROR: SNI_DEFAULT is required. Example: SNI_DEFAULT=192.168.1.10:443" >&2
  exit 1
fi

SNI_DEFAULT_IP="$(echo "$SNI_DEFAULT"   | cut -d: -f1)"
SNI_DEFAULT_PORT="$(echo "$SNI_DEFAULT" | cut -d: -f2)"

# --------------------------------------------------------------------------
# Build use_backend ACL lines and backend blocks for SNI_ROUTE_N vars
# --------------------------------------------------------------------------
SNI_ACL_LINES=""
SNI_BACKEND_BLOCKS=""
i=1

while true; do
  eval "val=\${SNI_ROUTE_${i}:-}"
  [ -z "$val" ] && break

  hostname="$(echo "$val" | cut -d: -f1)"
  ip="$(echo "$val"       | cut -d: -f2)"
  port="$(echo "$val"     | cut -d: -f3)"
  name="sni_backend_${i}"
  opts="$(server_opts)"

  if [ -z "$hostname" ] || [ -z "$ip" ] || [ -z "$port" ]; then
    echo "[sni-router] ERROR: SNI_ROUTE_${i}='${val}' must follow hostname:ip:port format." >&2
    exit 1
  fi

  # Wildcard: *.example.com  →  req.ssl_sni ends with .example.com
  case "$hostname" in
    \*.*)
      suffix="${hostname#\*}"   # strip leading '*' → .example.com
      acl="  use_backend ${name} if { req.ssl_sni -m end ${suffix} }"
      ;;
    *)
      acl="  use_backend ${name} if { req.ssl_sni -i ${hostname} }"
      ;;
  esac

  SNI_ACL_LINES="${SNI_ACL_LINES}
${acl}"

  SNI_BACKEND_BLOCKS="${SNI_BACKEND_BLOCKS}
backend ${name}
  server s1 ${ip}:${port} ${opts}
"

  i=$((i + 1))
done

# --------------------------------------------------------------------------
# Build frontend + backend blocks for TCP_ROUTE_N vars (plain TCP, no TLS)
# --------------------------------------------------------------------------
TCP_BLOCKS=""
j=1

while true; do
  eval "val=\${TCP_ROUTE_${j}:-}"
  [ -z "$val" ] && break

  lport="$(echo "$val" | cut -d: -f1)"
  ip="$(echo "$val"    | cut -d: -f2)"
  dport="$(echo "$val" | cut -d: -f3)"
  name="tcp_backend_${j}"
  opts="$(server_opts)"

  if [ -z "$lport" ] || [ -z "$ip" ] || [ -z "$dport" ]; then
    echo "[sni-router] ERROR: TCP_ROUTE_${j}='${val}' must follow listen_port:ip:dest_port format." >&2
    exit 1
  fi

  TCP_BLOCKS="${TCP_BLOCKS}
frontend tcp_frontend_${j}
  bind *:${lport}
  default_backend ${name}

backend ${name}
  server s1 ${ip}:${dport} ${opts}
"

  j=$((j + 1))
done

# --------------------------------------------------------------------------
# Build stats block (optional)
# --------------------------------------------------------------------------
STATS_BLOCK=""
if [ "$STATS_ENABLED" = "true" ]; then
  if [ -n "$STATS_PASSWORD" ]; then
    AUTH_LINE="  stats auth admin:${STATS_PASSWORD}"
  else
    AUTH_LINE=""
  fi
  STATS_BLOCK="
listen stats
  bind *:${STATS_PORT}
  stats enable
  stats uri /stats
  stats refresh 10s
  stats show-legends
  stats show-node
  stats hide-version
${AUTH_LINE}
"
fi

# --------------------------------------------------------------------------
# Assemble and write haproxy.cfg
# --------------------------------------------------------------------------
DEFAULT_OPTS="$(server_opts)"

cat > "$CFG" <<HAPROXY_CFG
global
  log stdout format raw local0 info
  maxconn 50000

defaults
  mode tcp
  log global
  option tcplog
  timeout connect 5s
  timeout client 300s
  timeout server 300s

frontend sni_tls
  bind *:${LISTEN_PORT}
  tcp-request inspect-delay 5s
  tcp-request content accept if { req.ssl_hello_type 1 }
${SNI_ACL_LINES}
  default_backend sni_default

backend sni_default
  server s1 ${SNI_DEFAULT_IP}:${SNI_DEFAULT_PORT} ${DEFAULT_OPTS}
${SNI_BACKEND_BLOCKS}${TCP_BLOCKS}${STATS_BLOCK}
HAPROXY_CFG

# --------------------------------------------------------------------------
# Show generated config and validate before starting
# --------------------------------------------------------------------------
echo "[sni-router] ---- Generated ${CFG} ----"
cat "$CFG"
echo "[sni-router] ----------------------------------"

echo "[sni-router] Validating config..."
if ! haproxy -c -f "$CFG"; then
  echo "[sni-router] ERROR: Invalid config. Aborting." >&2
  exit 1
fi

echo "[sni-router] Config OK. Starting HAProxy..."
exec "$@"
