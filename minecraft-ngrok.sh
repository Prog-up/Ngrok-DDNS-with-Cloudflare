#!/usr/bin/env bash
# =============================================================================
#  minecraft-ngrok.sh
#  Starts an ngrok TCP tunnel for a Minecraft server, waits for it to be ready,
#  then creates/updates a Cloudflare CNAME + SRV record pair so players can
#  connect using just the domain name without specifying a port.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — edit these values before deploying
# -----------------------------------------------------------------------------

# Cloudflare API Token (NOT the Global API Key).
# Required permissions: Zone > DNS > Edit  (scoped to your zone only)
CF_API_TOKEN="YOUR_CF_API_TOKEN"

CF_ZONE_ID="YOUR_ZONE_ID"         # Cloudflare Zone ID (found in your zone's Overview page)
CF_DOMAIN="mc.example.com"        # Subdomain players will connect to
CF_ROOT_DOMAIN="example.com"      # Apex domain (used to scope DNS listing queries)

# Local Minecraft server port
MC_PORT=25565

# How long (seconds) to wait for ngrok before giving up
NGROK_WAIT_TIMEOUT=60

# ngrok local API base URL
NGROK_API="http://127.0.0.1:4040/api/tunnels"

# -----------------------------------------------------------------------------
# DEPENDENCY CHECK — fail immediately if required tools are missing
# -----------------------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in curl jq ngrok; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[!] Missing required dependencies: ${missing[*]}" >&2
        echo "    Install them and try again." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# WAIT FOR NGROK — polls the local API until a TCP tunnel appears or times out
# -----------------------------------------------------------------------------
wait_for_ngrok() {
    echo "[*] Waiting for ngrok tunnel to become available (timeout: ${NGROK_WAIT_TIMEOUT}s)..." >&2
    local elapsed=0
    local interval=2

    while (( elapsed < NGROK_WAIT_TIMEOUT )); do
        # Attempt to query the local ngrok API; suppress errors
        local response
        response=$(curl -sf "$NGROK_API" 2>/dev/null) || true

        if [[ -n "$response" ]]; then
            local tunnel
            tunnel=$(echo "$response" | jq -r '.tunnels[] | select(.proto=="tcp") | .public_url' 2>/dev/null | head -n1)
            if [[ -n "$tunnel" ]]; then
                echo "[+] ngrok tunnel is up: $tunnel" >&2
                echo "$tunnel"   # caller captures this
                return 0
            fi
        fi

        sleep "$interval"
        (( elapsed += interval ))
    done

    echo "[!] Timed out waiting for ngrok TCP tunnel after ${NGROK_WAIT_TIMEOUT}s." >&2
    exit 1
}

# -----------------------------------------------------------------------------
# CLOUDFLARE HELPERS
# -----------------------------------------------------------------------------

# Wrapper: makes an authenticated Cloudflare API call and checks .success
cf_api() {
    local method="$1"
    local endpoint="$2"
    shift 2   # remaining args passed to curl as --data or ignored

    local response
    response=$(curl -sf -X "$method" \
        "https://api.cloudflare.com/client/v4${endpoint}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@")

    local success
    success=$(echo "$response" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        local errors
        errors=$(echo "$response" | jq -c '.errors')
        echo "[!] Cloudflare API error on ${method} ${endpoint}: ${errors}" >&2
        return 1
    fi

    echo "$response"
}

# Returns the record ID for a given type+name, or empty string if not found
get_record_id() {
    local type="$1"
    local name="$2"
    cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=${type}&name=${name}" \
        | jq -r '.result[0].id // empty'
}

# Upserts a DNS record (creates if absent, updates if present)
upsert_record() {
    local type="$1"
    local payload="$2"
    local name
    name=$(echo "$payload" | jq -r '.name')

    local existing_id
    existing_id=$(get_record_id "$type" "$name") || true

    if [[ -n "$existing_id" ]]; then
        echo "[*] Updating existing ${type} record for ${name} (id: ${existing_id})..."
        cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${existing_id}" --data "$payload" > /dev/null
    else
        echo "[*] Creating new ${type} record for ${name}..."
        cf_api POST "/zones/${CF_ZONE_ID}/dns_records" --data "$payload" > /dev/null
    fi
    echo "[+] ${type} record for ${name} upserted successfully."
}

# -----------------------------------------------------------------------------
# DNS UPDATE — sets the CNAME + SRV pair
# -----------------------------------------------------------------------------
# Why both records?
#
#   CNAME  mc.example.com  →  x.tcp.ngrok.io
#     Resolves the ngrok hostname to an IP. Cloudflare must NOT proxy
#     this (orange cloud off) because Minecraft uses raw TCP, not HTTP.
#
#   SRV  _minecraft._tcp.mc.example.com  →  0 5 <PORT>  mc.example.com
#     Tells the Minecraft client which port to use when connecting to
#     mc.example.com, so players never need to type the port manually.
#     The SRV target points at the CNAME, not the raw ngrok host, so
#     only one record needs to change each time ngrok restarts.
# -----------------------------------------------------------------------------
update_cloudflare_dns() {
    local ngrok_host="$1"   # e.g. 0.tcp.ngrok.io
    local ngrok_port="$2"   # e.g. 12345

    echo "[*] Updating Cloudflare DNS for ${CF_DOMAIN}..."
    echo "    ngrok endpoint → ${ngrok_host}:${ngrok_port}"

    # 1. CNAME: mc.example.com → 0.tcp.ngrok.io (proxied: false — raw TCP)
    local cname_payload
    cname_payload=$(jq -n \
        --arg name    "$CF_DOMAIN" \
        --arg content "$ngrok_host" \
        '{type:"CNAME", name:$name, content:$content, ttl:0, proxied:false}')
    upsert_record "CNAME" "$cname_payload"

    # 2. SRV: _minecraft._tcp.mc.example.com → 0 5 <PORT> mc.example.com
    #    SRV record format: priority=0, weight=5, port=<ngrok_port>, target=<CF_DOMAIN>
    local srv_name="_minecraft._tcp.${CF_DOMAIN}"
    local srv_payload
    srv_payload=$(jq -n \
        --arg  name     "$srv_name" \
        --arg  target   "$CF_DOMAIN" \
        --argjson port  "$ngrok_port" \
        '{
            type: "SRV",
            name: $name,
            ttl:  0,
            data: {
                service:  "_minecraft",
                proto:    "_tcp",
                name:     $name,
                priority: 0,
                weight:   5,
                port:     $port,
                target:   $target
            }
        }')
    upsert_record "SRV" "$srv_payload"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    check_deps

    echo "[*] Starting ngrok TCP tunnel on local port ${MC_PORT}..."
    # Run ngrok in the foreground but redirect its output to a log file.
    # We exec it last (after Cloudflare updates) so systemd tracks the PID.
    ngrok tcp "$MC_PORT" --log=stdout --log-format=json > /var/log/ngrok.log 2>&1 &
    NGROK_PID=$!
    echo "[*] ngrok PID: ${NGROK_PID}"

    # Poll until the tunnel is ready, then capture the public URL
    NGROK_TUNNEL=$(wait_for_ngrok)

    # Parse host and port out of tcp://0.tcp.ngrok.io:12345
    NGROK_HOST=$(echo "$NGROK_TUNNEL" | sed 's|tcp://||' | cut -d':' -f1)
    NGROK_PORT=$(echo "$NGROK_TUNNEL" | sed 's|tcp://||' | cut -d':' -f2)

    update_cloudflare_dns "$NGROK_HOST" "$NGROK_PORT"

    echo ""
    echo "============================================================"
    echo "  Minecraft server is live!"
    echo "  Players connect to:  ${CF_DOMAIN}  (no port needed)"
    echo "  ngrok endpoint:      ${NGROK_HOST}:${NGROK_PORT}"
    echo "============================================================"
    echo ""

    # Hand control to ngrok so systemd can track *it* from here on.
    # If ngrok dies, systemd sees the unit exit and can restart it.
    wait "$NGROK_PID"
}

main "$@"
