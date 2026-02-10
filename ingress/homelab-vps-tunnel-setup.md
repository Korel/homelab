# Homelab VPS Tunnel Setup

## Overview

Replace Cloudflare Tunnel with a self-hosted TCP passthrough proxy on an Oracle Cloud VPS, connected to a homelab via Tailscale. This gives you true end-to-end encryption — the VPS only forwards raw TCP bytes and **cannot read your traffic**.

### Why?

- **Cloudflare terminates TLS** at their edge — they can see all your traffic in plaintext
- A TCP passthrough proxy only sees encrypted bytes flowing through
- Your home IP stays hidden behind the VPS IP
- No upload size limits (Cloudflare free tier limits to 100MB)

### Architecture

```
Client ←TLS→ Oracle VPS (TCP passthrough) ←Tailscale→ Caddy (TLS termination) → Services
```

Cloudflare never touches your traffic. Caddy handles all TLS with your own Let's Encrypt certs.

---

## Prerequisites

- Oracle Cloud VPS (free tier works) with a **reserved static IP**
- Tailscale installed on both the VPS and homelab
- Caddy on the homelab with DNS challenge for Let's Encrypt certs
- DNS managed via Cloudflare (or any provider)

---

## 1. Reserve a Static IP on Oracle Cloud

1. Go to **Networking → IP Management → Reserved Public IPs**
2. Click **Reserve Public IP Address**
3. Go to **Compute → Instances → your VM → Attached VNICs → VNIC → IPv4 Addresses**
4. Edit the primary private IP → set **No public IP** → save
5. Edit again → select **Reserved Public IP** → pick your reserved IP

> Reserved IPs are free when attached to an instance.

---

## 2. Install and Configure Nginx

### Install nginx with stream and geoip2 modules

```bash
sudo apt update && sudo apt install -y nginx-full
```

Verify the modules exist:

```bash
ls /usr/lib/nginx/modules/ | grep -E "stream|geoip"
```

### Remove default site

```bash
sudo rm /etc/nginx/sites-enabled/default
```

### Configure TCP stream proxy with geo-blocking

Edit `/etc/nginx/modules-enabled/stream.conf`:

```nginx
stream {
    geoip2 /var/lib/GeoIP/GeoLite2-Country.mmdb {
        $geo_country_code country iso_code;
    }

    map $geo_country_code $backend {
        default "127.0.0.1:4443";
        DE <TAILSCALE_IP>:443;
        # Add more countries:
        # TR <TAILSCALE_IP>:443;
        # NL <TAILSCALE_IP>:443;
        # GB <TAILSCALE_IP>:443;
        # BE <TAILSCALE_IP>:443;
    }

    map $geo_country_code $backend_http {
        default "127.0.0.1:8404";
        DE <TAILSCALE_IP>:80;
        # TR <TAILSCALE_IP>:80;
        # NL <TAILSCALE_IP>:80;
        # GB <TAILSCALE_IP>:80;
        # BE <TAILSCALE_IP>:80;
    }

    map $geo_country_code $backend_udp {
        default "127.0.0.1:4443";
        DE <TAILSCALE_IP>:443;
        # TR <TAILSCALE_IP>:443;
        # NL <TAILSCALE_IP>:443;
        # GB <TAILSCALE_IP>:443;
        # BE <TAILSCALE_IP>:443;
    }

    # HTTPS
    server {
        listen 443;
        proxy_pass $backend;
    }

    # HTTP3/QUIC
    server {
        listen 443 udp;
        proxy_pass $backend_udp;
    }

    # HTTP
    server {
        listen 80;
        proxy_pass $backend_http;
    }
}
```

### Geo-block page (served to blocked countries)

Add this inside the `http { }` block in `/etc/nginx/nginx.conf`:

```nginx
server {
    listen 127.0.0.1:4443 ssl http2;
    listen 127.0.0.1:8404;
    server_name *.example.com example.com;
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    default_type text/html;
    return 403 '<html><head><meta charset="utf-8"></head><body><h1>🌍 Geo-blocked</h1><p>Add your country to the allow list on the VPS.</p><p>Edit: /etc/nginx/modules-enabled/stream.conf</p></body></html>';
}
```

### Test and reload

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 3. Set Up GeoIP2 Database (MaxMind)

### Create a free MaxMind account

Sign up at: https://www.maxmind.com/en/geolite-free-ip-geolocation-data

Generate a license key from your account settings.

### Install geoipupdate

```bash
sudo apt install -y geoipupdate
```

### Configure

Edit `/etc/GeoIP.conf`:

```
AccountID <YOUR_ACCOUNT_ID>
LicenseKey <YOUR_LICENSE_KEY>
EditionIDs GeoLite2-Country
```

### Download and verify

```bash
sudo geoipupdate
ls /var/lib/GeoIP/GeoLite2-Country.mmdb
```

> `geoipupdate` has a systemd timer that auto-updates the database.

---

## 4. Set Up Certbot for the Geo-block Page

The block page needs a valid TLS cert so browsers don't show warnings.

### Install certbot with Cloudflare plugin

```bash
sudo apt install -y certbot python3-certbot-dns-cloudflare
```

### Create Cloudflare credentials

```bash
sudo tee /etc/letsencrypt/cloudflare.ini > /dev/null << 'EOF'
dns_cloudflare_api_token = <YOUR_CLOUDFLARE_API_TOKEN>
EOF
sudo chmod 600 /etc/letsencrypt/cloudflare.ini
```

### Get a wildcard certificate

```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d "*.example.com" -d "example.com"
```

### Auto-reload nginx on renewal

```bash
echo 'deploy-hook = systemctl reload nginx' | sudo tee -a /etc/letsencrypt/renewal/example.com.conf
```

---

## 5. Open Firewall Ports

### iptables (on the VPS)

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

### Oracle VCN Security List

In the Oracle Cloud console, go to **Networking → VCN → Security Lists → Ingress Rules** and add:

| Protocol | Port | Source    | Description |
|----------|------|-----------|-------------|
| TCP      | 80   | 0.0.0.0/0 | HTTP        |
| TCP      | 443  | 0.0.0.0/0 | HTTPS       |
| UDP      | 443  | 0.0.0.0/0 | QUIC/HTTP3  |

---

## 6. Update DNS Records

Point your domains to the VPS static IP (DNS only, no Cloudflare proxy):

| Type | Name | Value             | Proxy   |
|------|------|-------------------|---------|
| A    | @    | `<VPS_PUBLIC_IP>` | DNS only |
| A    | *    | `<VPS_PUBLIC_IP>` | DNS only |

Keep local and Tailscale records for direct access:

| Type | Name | Value              | Proxy    |
|------|------|--------------------|----------|
| A    | l    | `192.168.x.x`     | DNS only |
| A    | *.l  | `192.168.x.x`     | DNS only |
| A    | ts   | `<TAILSCALE_IP>`   | DNS only |
| A    | *.ts | `<TAILSCALE_IP>`   | DNS only |

---

## Adding a New Country

Edit `/etc/nginx/modules-enabled/stream.conf` and add the country code to **all three maps** (`$backend`, `$backend_http`, `$backend_udp`):

```nginx
TR <TAILSCALE_IP>:443;   # Turkey
NL <TAILSCALE_IP>:443;   # Netherlands
GB <TAILSCALE_IP>:443;   # United Kingdom
BE <TAILSCALE_IP>:443;   # Belgium
```

Then reload:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### Common Country Codes

| Code | Country        |
|------|----------------|
| DE   | Germany        |
| TR   | Turkey         |
| NL   | Netherlands    |
| GB   | United Kingdom |
| BE   | Belgium        |
| AT   | Austria        |
| FR   | France         |
| CH   | Switzerland    |

---

## Troubleshooting

### Check nginx is listening

```bash
sudo ss -tlnp | grep -E "80|443|4443|8404"
```

### Check nginx error log

```bash
sudo tail -20 /var/log/nginx/error.log
```

### Test connectivity from VPS to homelab

```bash
curl -v https://<TAILSCALE_IP>
```

### Test geo-blocking

```bash
# From allowed country (should return your site)
curl -v --resolve "example.com:443:<VPS_IP>" https://example.com

# From blocked country via VPN (should return 403 geo-block page)
curl -v --resolve "example.com:443:<VPS_IP>" https://example.com
```

### Tailscale ACLs

Make sure your Tailscale ACLs allow the VPS to reach your homelab on ports 80 and 443.

---

## Security Notes

- **Oracle VPS** can see connection metadata (IPs, timestamps, data volume) but **cannot read traffic contents** — it only forwards encrypted TCP bytes
- **Home IP** is hidden behind the VPS IP and Tailscale tunnel
- **CrowdSec** on the homelab (with Caddy) still works for application-layer protection since it sees real source IPs
- **GeoIP blocking** happens at the VPS level, saving tunnel bandwidth
- Services with client-side encryption (Vaultwarden, Atuin, Obsidian LiveSync) have an extra layer of protection regardless of the tunnel setup
