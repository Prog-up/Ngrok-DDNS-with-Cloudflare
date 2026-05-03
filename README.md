# Ngrok-DDNS with Cloudflare — Minecraft Edition

> Expose a home-hosted Minecraft server through a custom domain, for free — no router config, no static IP, no port forwarding required.

This project automates an ngrok TCP tunnel and keeps your Cloudflare DNS in sync every time the tunnel restarts. Players connect using just your domain (`mc.yourdomain.com`) — no manual port appending — thanks to a properly configured **SRV record** pair.

---

## How It Works

```
Player types: mc.yourdomain.com
        │
        ▼
Minecraft client performs SRV lookup
  _minecraft._tcp.mc.yourdomain.com
        │
        ▼
SRV record returns: port=XXXXX, target=mc.yourdomain.com
        │
        ▼
Client resolves CNAME: mc.yourdomain.com → X.tcp.ngrok.io
        │
        ▼
Client connects to: X.tcp.ngrok.io:XXXXX  ✓
```

On every boot, the script starts ngrok, waits until the tunnel is live, then updates both DNS records automatically. The SRV record handles port discovery so players never need to type `:PORT`.

---

## Features

| Feature | Details |
|---|---|
| **SRV + CNAME pair** | Players connect with just the domain; no port suffix needed |
| **Cloudflare API Token auth** | Scoped, revocable tokens — not the dangerous Global API Key |
| **Reliable startup** | Polls the ngrok API in a loop instead of a blind `sleep` |
| **Dependency check** | Exits immediately with a clear error if `curl`, `jq`, or `ngrok` are missing |
| **Upsert logic** | Creates DNS records if absent, updates them if present — no manual pre-setup required |
| **systemd integration** | Ships with a full `.service` file for automatic startup and restart on failure |
| **Least-privilege ready** | Service runs as a dedicated low-privilege user |

---

## Prerequisites

- A domain managed on [Cloudflare](https://cloudflare.com) (free tier is fine)
- A **Cloudflare API Token** with `Zone > DNS > Edit` permission ([how to create one →](#3-create-a-cloudflare-api-token))
- `ngrok` installed and authenticated
- `jq` and `curl` installed
- A Minecraft server running locally on port 25565 (or whichever port you configure)

---

## Installation

### 1. Install dependencies

**On Ubuntu / Debian:**

```bash
# jq and curl
sudo apt-get update && sudo apt-get install -y jq curl

# ngrok (official APT repository — recommended over the old zip method)
curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
  | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null

echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
  | sudo tee /etc/apt/sources.list.d/ngrok.list

sudo apt-get update && sudo apt-get install -y ngrok
```

**On other systems:** see the [official ngrok download page](https://ngrok.com/download).

### 2. Authenticate ngrok

Sign up at [ngrok.com](https://ngrok.com) (free), copy your authtoken from the dashboard, then run:

```bash
ngrok config add-authtoken YOUR_NGROK_AUTHTOKEN
```

### 3. Create a Cloudflare API Token

1. Go to **My Profile → API Tokens → Create Token** in the Cloudflare dashboard.
2. Use the **Edit zone DNS** template, or create a custom token with:
   - **Permissions:** `Zone > DNS > Edit`
   - **Zone Resources:** Include → Specific zone → *your zone*
3. Copy the token — you won't be able to see it again.

> **Why a Token and not the Global API Key?**
> The Global API Key has unrestricted access to your entire Cloudflare account. An API Token is scoped to a single zone's DNS and can be revoked independently. Always prefer tokens.

### 4. Find your Cloudflare Zone ID

Your Zone ID is displayed in the **Overview** tab of your domain in the Cloudflare dashboard (right-hand sidebar). Copy it — you'll need it in the next step.

### 5. Configure the script

Open `minecraft-ngrok.sh` and fill in the variables at the top:

```bash
# Cloudflare
CF_API_TOKEN="YOUR_CF_API_TOKEN"    # The scoped API Token you created above
CF_ZONE_ID="YOUR_ZONE_ID"           # Found in the Cloudflare dashboard Overview tab
CF_DOMAIN="mc.yourdomain.com"       # The subdomain players will use
CF_ROOT_DOMAIN="yourdomain.com"     # Your apex domain

# Minecraft
MC_PORT=25565                       # Local Minecraft server port (default: 25565)

# Timeout
NGROK_WAIT_TIMEOUT=60               # Seconds to wait for ngrok before giving up
```

> **No `CF_RECORD_ID` needed.** The script uses the Cloudflare API to look up existing records by name and type, and creates them if they don't exist. You don't need to pre-create any DNS records.

### 6. Make the script executable

```bash
chmod +x minecraft-ngrok.sh
sudo cp minecraft-ngrok.sh /usr/local/bin/minecraft-ngrok.sh
```

---

## Running Manually

```bash
./minecraft-ngrok.sh
```

A successful run looks like this:

```
[*] Starting ngrok TCP tunnel on local port 25565...
[*] ngrok PID: 12345
[*] Waiting for ngrok tunnel to become available (timeout: 60s)...
[+] ngrok tunnel is up: tcp://0.tcp.ngrok.io:19823
[*] Updating Cloudflare DNS for mc.yourdomain.com...
    ngrok endpoint → 0.tcp.ngrok.io:19823
[*] Updating existing CNAME record for mc.yourdomain.com (id: abc123)...
[+] CNAME record for mc.yourdomain.com upserted successfully.
[*] Creating new SRV record for _minecraft._tcp.mc.yourdomain.com...
[+] SRV record for _minecraft._tcp.mc.yourdomain.com upserted successfully.

============================================================
  Minecraft server is live!
  Players connect to:  mc.yourdomain.com  (no port needed)
  ngrok endpoint:      0.tcp.ngrok.io:19823
============================================================
```

---

## Running as a systemd Service (Recommended)

The included `minecraft-ngrok.service` file manages the script as a proper system service: starts at boot, restarts on failure, and logs to the system journal.

### Setup

```bash
# 1. Create a dedicated low-privilege service user
sudo useradd -r -s /sbin/nologin ngrok-dns

# 2. Create a config directory owned by the service user
sudo mkdir -p /etc/ngrok
sudo chown ngrok-dns:ngrok-dns /etc/ngrok
sudo chmod 700 /etc/ngrok   # only ngrok-dns can read it (contains a secret)

# 3. Write the config file
sudo -u ngrok-dns bash -c 'cat > /etc/ngrok/ngrok.yml' << 'EOF'
version: "3"
agent:
  authtoken: YOUR_NGROK_AUTHTOKEN
EOF

# 4. Lock down permissions
sudo chmod 600 /etc/ngrok/ngrok.yml

# 5. Create and own the ngrok log file
sudo touch /var/log/ngrok.log
sudo chown ngrok-dns:ngrok-dns /var/log/ngrok.log

# 6. Install the service file
sudo cp minecraft-ngrok.service /etc/systemd/system/

# 7. Reload systemd and enable the service
sudo systemctl daemon-reload
sudo systemctl enable --now minecraft-ngrok.service
```

### Managing the service

```bash
# Check current status
sudo systemctl status minecraft-ngrok

# View live logs
sudo journalctl -u minecraft-ngrok -f

# Restart manually (e.g. after a config change)
sudo systemctl restart minecraft-ngrok

# Disable autostart
sudo systemctl disable minecraft-ngrok
```

### Service file highlights

| Setting | Value | Reason |
|---|---|---|
| `After=` | `network-online.target` | Waits for a real network connection, not just interface up |
| `Restart=on-failure` | — | Re-establishes the tunnel if ngrok drops |
| `RestartSec=15s` | — | Brief cooldown before reconnect attempts |
| `TimeoutStartSec=90s` | — | Enough time for the ngrok polling loop to complete |
| `User=ngrok-dns` | — | Least-privilege: no shell, no home directory |
| `NoNewPrivileges=true` | — | Prevents privilege escalation |
| `ProtectSystem=strict` | — | Read-only filesystem except for the log path |

If your Minecraft server is also managed by systemd (e.g. a `minecraft.service` unit), uncomment the `Requires=minecraft.service` line in the service file so the tunnel only starts when the server is actually running.

---

## DNS Record Reference

The script creates and manages two records:

### CNAME record

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | `mc.yourdomain.com` |
| Target | `0.tcp.ngrok.io` *(set dynamically)* |
| TTL | 60 seconds |
| Proxied | ❌ Off — Cloudflare's proxy doesn't support raw TCP |

### SRV record

| Field | Value |
|---|---|
| Type | `SRV` |
| Name | `_minecraft._tcp.mc.yourdomain.com` |
| Priority | `0` |
| Weight | `5` |
| Port | *(set dynamically by ngrok)* |
| Target | `mc.yourdomain.com` |
| TTL | 60 seconds |

The SRV target deliberately points at the CNAME, not the raw ngrok hostname. This keeps the two records decoupled: if the ngrok endpoint host changes (rare), only the CNAME needs updating; if only the port changes (common on every restart), only the SRV needs updating.

---

## Why Not HTTP/HTTPS?

This script is intentionally TCP-only. HTTP/HTTPS tunnels won't work for Minecraft because:

1. Minecraft's network protocol is not HTTP — it speaks its own binary protocol over raw TCP.
2. Cloudflare can only proxy HTTP/HTTPS traffic through its CDN; raw TCP is passed through at DNS level only.
3. Even if you used an HTTP tunnel, ngrok wouldn't issue an SSL certificate for your custom domain on a free plan.

If you want to expose a web service (not Minecraft), you'll need either a paid ngrok plan or a reverse proxy such as Nginx or Caddy sitting in front of your app.

---

## Limitations

| Limitation | Details |
|---|---|
| **ngrok free plan** | One concurrent TCP tunnel per account; tunnel restarts on session timeout (~8 hours). The systemd service handles reconnection automatically. |
| **DNS propagation** | TTL is set to 60 seconds to minimize stale-cache time, but some resolvers may take longer to pick up changes. |
| **No fixed port** | ngrok's free tier assigns a random external port on each restart. The SRV record is updated automatically each time, so players are unaffected as long as their client respects SRV lookups (the vanilla Minecraft client does). |
| **Cloudflare proxy** | Must be disabled (grey cloud) for the CNAME record. Cloudflare's proxy only handles HTTP/HTTPS — raw TCP would be dropped. |

---

## Troubleshooting

**`[!] Missing required dependencies: jq`**
Install the missing tool (`sudo apt-get install jq`) and re-run.

**`[!] Timed out waiting for ngrok TCP tunnel after 60s`**
- Confirm your ngrok authtoken is configured: `ngrok config check`
- Check if another ngrok tunnel is already running (free tier allows only one at a time)
- Increase `NGROK_WAIT_TIMEOUT` in the script if you're on a very slow connection

**`[!] Cloudflare API error`**
- Verify `CF_API_TOKEN` has `Zone > DNS > Edit` permission
- Confirm `CF_ZONE_ID` matches the zone your domain belongs to
- Check the full error JSON printed to stderr for Cloudflare's specific error code

**Players can connect via `host:port` but not via the plain domain**
SRV lookups require a short DNS propagation delay after the first run. Wait ~60 seconds (the configured TTL) and retry. You can verify the SRV record is live with:
```bash
dig SRV _minecraft._tcp.mc.yourdomain.com
```

---

## Contributing

Issues and pull requests are welcome. When reporting a bug, please include:

- Your OS and shell version (`bash --version`)
- The relevant lines from `journalctl -u minecraft-ngrok` or terminal output
- Whether the failure is on startup, during polling, or during the Cloudflare API call
