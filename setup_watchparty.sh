#!/usr/bin/env bash
set -euo pipefail

# Ensure script is executed by a regular user with sudo privileges
if [ "$EUID" -eq 0 ]; then
  echo "Error: Do not run this script directly as root. Run it as a standard user with sudo access."
  exit 1
fi

echo "=========================================="
echo " WatchParty Setup Script"
echo "=========================================="
echo "Select your target operating system:"
echo "1) Debian / Ubuntu base (uses apt)"
echo "2) Fedora base (uses dnf)"
echo "3) Auto-detect OS"
read -r -p "Enter choice [1-3] (default: 3): " choice

case "${choice:-3}" in
  1)
    DISTRO="debian"
    ;;
  2)
    DISTRO="fedora"
    ;;
  3|*)
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      if [[ "${ID:-}" == "fedora" ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then
        DISTRO="fedora"
      elif [[ "${ID:-}" =~ ^(debian|ubuntu|pop|mint)$ ]] || [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
        DISTRO="debian"
      else
        echo "Could not auto-detect distribution. Defaulting to Debian/Ubuntu."
        DISTRO="debian"
      fi
    else
      DISTRO="debian"
    fi
    ;;
esac

echo "==> Operating system profile selected: ${DISTRO}"

echo "==> [1/9] Installing core dependencies..."
if [ "$DISTRO" = "debian" ]; then
  sudo apt-get update
  sudo apt-get install -y curl git openssl jq ca-certificates gnupg
  if ! command -v docker &> /dev/null; then
    sudo apt-get install -y docker.io docker-compose-v2
    sudo usermod -aG docker "$USER"
  fi
elif [ "$DISTRO" = "fedora" ]; then
  sudo dnf install -y curl git openssl jq ca-certificates
  if ! command -v docker &> /dev/null; then
    sudo dnf install -y docker docker-compose
    sudo usermod -aG docker "$USER"
  fi
fi

# Install Tailscale if not present
if ! command -v tailscale &> /dev/null; then
  echo "==> [2/9] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> [3/9] Enabling Docker and Tailscale services on system boot..."
sudo systemctl enable --now docker
sudo systemctl enable --now tailscaled

echo "==> [4/9] Verifying Tailscale authentication..."
if ! tailscale status &> /dev/null; then
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

echo "==> [5/9] Preparing directory structure and repository source..."
mkdir -p "$HOME/Videos"

if [ ! -d "ott-source" ]; then
  echo "Cloning OpenTogetherTube repository into ./ott-source..."
  git clone https://github.com/dyc3/opentogethertube.git ott-source
fi

echo "==> [6/9] Generating configuration files..."

# 1. Create nginx.conf
cat << 'EOF' > nginx.conf
server {
    listen 80;
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

# 2. Generate random secrets
API_KEY=$(openssl rand -hex 20)        # 40 characters
SESSION_SECRET=$(openssl rand -hex 40)  # 80 characters

# 3. Create production.toml
cat << EOF > production.toml
hostname="${MAGIC_DNS}"

log = { level="info" }

api_key="${API_KEY}"
session_secret="${SESSION_SECRET}"

[info_extractor.youtube]
api_key=""
EOF

# 4. Create docker-compose.yml
cat << EOF > docker-compose.yml
services:
  db:
    image: postgres:15-alpine
    restart: "no"
    environment:
      POSTGRES_USER: ott_user
      POSTGRES_PASSWORD: ott_password
      POSTGRES_DB: opentogethertube
    volumes:
      - postgres-data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: "no"

  opentogethertube:
    build:
      context: ./ott-source
      dockerfile: deploy/monolith.Dockerfile
      args:
        DEPLOY_TARGET: base
    restart: "no"
    ports:
      - "8080:8080"
    environment:
      - DATABASE_URL=postgres://ott_user:ott_password@db:5432/opentogethertube
      - REDIS_URL=redis://redis:6379
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro,z
      - ./production.toml:/app/env/production.toml:ro,z
      - ${HOME}/Videos:/usr/share/nginx/html:ro,z
    depends_on:
      - db
      - redis

  videoserver:
    image: nginx:alpine
    restart: "no"
    ports:
      - "8081:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${HOME}/Videos:/usr/share/nginx/html:ro

volumes:
  postgres-data:
EOF

echo "==> [7/9] Setting up persistent Tailscale Funnels in background..."
sudo tailscale serve --bg 8080
sudo tailscale serve --bg --https=8443 8081

echo "==> [8/9] Launching Docker container stack..."
docker compose up -d

echo "==> [9/9] Waiting for PostgreSQL database initialization..."
until docker compose exec -T db pg_isready -U ott_user -d opentogethertube &> /dev/null; do
  echo "Database is starting up... waiting 3 seconds."
  sleep 3
done

echo "Running OpenTogetherTube database migrations..."
docker compose exec -T -w /app opentogethertube npm run db:migrate

echo ""
echo "========================================================================="
echo " Automation Complete! (${DISTRO} profile)"
echo " MagicDNS Domain : ${MAGIC_DNS}"
echo " App URL          : https://${MAGIC_DNS}/"
echo " Video Stream URL : https://${MAGIC_DNS}:8443/<video-file.mp4>"
echo "========================================================================="
echo ""
echo "All services and database migrations are ready."
echo "To stop the stack when finished: docker compose stop"
echo "To start the stack in the future: docker compose start"
echo "========================================================================="
