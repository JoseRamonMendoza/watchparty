#!/usr/bin/env bash
set -euo pipefail

# Ensure script is executed by a regular user with sudo privileges
if [ "$EUID" -eq 0 ]; then
  echo "Error: Do not run this script directly as root. Run it as a standard user with sudo access."
  exit 1
fi

echo "==> [1/8] Installing core dependencies..."

# Install dependencies if not pressent
for pkg in curl git openssl jq ca-certificates; do
  rpm -q "$pkg" &>/dev/null || (echo "==> Installing $pkg..." && sudo dnf install -y "$pkg")
done

if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker..."
  sudo dnf install -y docker docker-compose
  sudo usermod -aG docker "$USER"
fi

if ! command -v tailscale &>/dev/null; then
  echo "==> Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> [2/8] Enabling Docker and Tailscale services on system boot..."
for svc in docker tailscaled; do
  systemctl is-enabled "$svc" &>/dev/null || sudo systemctl enable --now "$svc"
done

echo "==> [3/8] Verifying Tailscale authentication..."
if ! tailscale status &>/dev/null; then
  echo "Tailscale is not connected. Authenticating now..."
  sudo tailscale up
fi

# Extract MagicDNS domain
MAGIC_DNS=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
if [ -z "$MAGIC_DNS" ] || [ "$MAGIC_DNS" = "null" ]; then
  echo "Error: Failed to retrieve MagicDNS domain from Tailscale. Ensure 'tailscale up' completes successfully."
  exit 1
fi
echo "Detected MagicDNS domain: ${MAGIC_DNS}"

echo "==> [4/8] Preparing directory structure and repository source..."
mkdir -p "$HOME/Videos"

if [ ! -d "ott-source" ]; then
  echo "Cloning OpenTogetherTube repository into ./ott-source..."
  git clone https://github.com/dyc3/opentogethertube.git ott-source
fi

echo "==> [5/8] Generating configuration files..."

# 1. Create nginx.conf
if [ ! -f nginx.conf ]; then
  cat <<'EOF' >nginx.conf
server {
    listen 8081;
    location / {
        root /usr/share/nginx/html;
        autoindex on;

        # CORS headers required for video streaming
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Origin, Range, Accept, Authorization, Content-Type' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;

        # Preflight OPTIONS request handler
        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'Origin, Range, Accept, Authorization, Content-Type' always;
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
    }
}
EOF
fi

# 2. Generate random secrets
if [ ! -f production.toml]; then
  API_KEY=$(openssl rand -hex 20)        # 40 characters
  SESSION_SECRET=$(openssl rand -hex 40) # 80 characters

  # 3. Create production.toml
  cat <<EOF >production.toml
hostname="${MAGIC_DNS}"

log = { level="info" }

api_key="${API_KEY}"
session_secret="${SESSION_SECRET}"

[info_extractor.youtube]
api_key=""
EOF
else
  # Update hostname dynamically if MagicDNS changed, preserving keys
  sed -i "s/^hostname=.*/hostname=\"${MAGIC_DNS}\"/" production.toml
fi

# 4. Create docker-compose.yml
cat <<EOF >docker-compose.yml
services:
  db:
    image: postgres:15-alpine
    restart: "no"
    network_mode: "host"
    environment:
      POSTGRES_USER: ott_user
      POSTGRES_PASSWORD: ott_password
      POSTGRES_DB: opentogethertube
    volumes:
      - postgres-data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: "no"
    network_mode: "host"

  opentogethertube:
    build:
      context: ./ott-source
      dockerfile: deploy/monolith.Dockerfile
      args:
        DEPLOY_TARGET: base
    restart: "no"
    network_mode: "host"
    environment:
      - DATABASE_URL=postgres://ott_user:ott_password@127.0.0.1:5432/opentogethertube
      - REDIS_URL=redis://127.0.0.1:6379
    volumes:
      - ./production.toml:/app/env/production.toml:ro,z
    depends_on:
      - db
      - redis

  videoserver:
    image: nginx:alpine
    restart: "no"
    network_mode: "host"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro,z
      - ${HOME}/Videos:/usr/share/nginx/html:ro,z

volumes:
  postgres-data:
EOF

echo "==> [6/8] Setting up persistent Tailscale Funnels in background..."
sudo tailscale serve --bg 8080
sudo tailscale serve --bg --https=8443 8081

echo "==> [7/8] Launching Docker container stack..."
docker compose up -d

echo "==> [8/8] Waiting for PostgreSQL database initialization..."
until docker compose exec -T db pg_isready -U ott_user -d opentogethertube &>/dev/null; do
  echo "Database is starting up... waiting 3 seconds."
  sleep 3
done

echo "Running OpenTogetherTube database migrations..."
docker compose exec -T -w /app opentogethertube npm run db:migrate

echo ""
echo "========================================================================="
echo " MagicDNS Domain : ${MAGIC_DNS}"
echo " App URL          : https://${MAGIC_DNS}/"
echo " Video Stream URL : https://${MAGIC_DNS}:8443/<video-file.mp4>"
echo "========================================================================="
echo ""
echo "All services and database migrations are ready."
echo "To stop the stack when finished: docker compose stop"
echo "To start the stack in the future: docker compose start"
echo "========================================================================="
