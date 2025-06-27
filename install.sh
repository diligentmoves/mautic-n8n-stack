#!/bin/bash

# Function to install Docker if not present
install_docker() {
    echo "🔧 Docker not found. Installing Docker & Docker Compose..."

    apt-get update && apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "✅ Docker and Docker Compose installed."
}

# Check for Docker and install if missing
if ! command -v docker &> /dev/null; then
    install_docker
fi

# Ensure docker-compose is accessible for legacy scripts
if ! command -v docker-compose &> /dev/null; then
    echo "🔁 Linking docker-compose plugin for compatibility..."
    ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose 2>/dev/null || true
fi

set -e

# Default values
DOMAIN=""
EMAIL=""
MAUTIC_SUB="m"
N8N_SUB="n8n"

# --- Helpers ---
print_header() {
    echo -e "\n\033[1;34m$1\033[0m\n"
}

fail() {
    echo -e "\n\033[0;31mERROR:\033[0m $1\n"
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not installed."
}

resolve_ip() {
    dig +short "$1" | tail -n1
}

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift ;;
        --email) EMAIL="$2"; shift ;;
        *) fail "Unknown parameter passed: $1" ;;
    esac
    shift
done

[ -z "$DOMAIN" ] && fail "--domain is required"
[ -z "$EMAIL" ] && fail "--email is required"

# --- Initial Checks ---
check_command docker
check_command docker-compose
check_command dig

PUBLIC_IP=$(curl -s https://api.ipify.org)
MAUTIC_HOST="$MAUTIC_SUB.$DOMAIN"
N8N_HOST="$N8N_SUB.$DOMAIN"

print_header "🔧 DNS Configuration Required"
echo "Please create the following DNS A records:"
echo "  - $MAUTIC_HOST  ➜  $PUBLIC_IP"
echo "  - $N8N_HOST     ➜  $PUBLIC_IP"

echo -e "\nWaiting for DNS propagation… (CTRL+C to cancel)"
while true; do
    MAUTIC_IP=$(resolve_ip "$MAUTIC_HOST")
    N8N_IP=$(resolve_ip "$N8N_HOST")

    echo -e "\nChecking records:"
    echo -n "  $MAUTIC_HOST ➜ $MAUTIC_IP "
    [[ "$MAUTIC_IP" == "$PUBLIC_IP" ]] && echo "✅" || echo "❌"

    echo -n "  $N8N_HOST    ➜ $N8N_IP "
    [[ "$N8N_IP" == "$PUBLIC_IP" ]] && echo "✅" || echo "❌"

    if [[ "$MAUTIC_IP" == "$PUBLIC_IP" && "$N8N_IP" == "$PUBLIC_IP" ]]; then
        break
    fi

    echo "Retrying in 30 seconds…"
    sleep 30
done

print_header "✅ DNS Propagation Complete"
echo "Proceeding with stack installation…"

# --- Generate Docker Compose File ---
print_header "⚙️ Creating Docker Compose Stack"

mkdir -p mautic-n8n-stack && cd mautic-n8n-stack

cat > docker-compose.yml <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:v2.10
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.tlschallenge=true"
      - "--certificatesresolvers.myresolver.acme.email=$EMAIL"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
    restart: unless-stopped

  mautic:
    image: mautic/mautic:v5
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mautic.rule=Host(\`$MAUTIC_HOST\`)"
      - "traefik.http.routers.mautic.entrypoints=websecure"
      - "traefik.http.routers.mautic.tls.certresolver=myresolver"
    environment:
      - MAUTIC_DB_HOST=db
      - MAUTIC_DB_NAME=mautic
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=mauticpass
    depends_on:
      - db
    restart: unless-stopped

  db:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD=rootpass
      MYSQL_DATABASE=mautic
      MYSQL_USER=mautic
      MYSQL_PASSWORD=mauticpass
    volumes:
      - db_data:/var/lib/mysql
    restart: unless-stopped

  n8n:
    image: n8nio/n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`$N8N_HOST\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
    environment:
      - DB_TYPE=sqlite
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=test1234#
    volumes:
      - n8n_data:/home/node/.n8n
    restart: unless-stopped

  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped

  gotenberg:
    image: gotenberg/gotenberg:7
    restart: unless-stopped

  rabbitmq:
    image: rabbitmq:3-management
    ports:
      - "15672:15672"
      - "5672:5672"
    restart: unless-stopped

volumes:
  db_data:
  n8n_data:
EOF

# Create directories
mkdir -p letsencrypt

print_header "🚀 Launching Docker Stack"
docker compose up -d

print_header "✅ Installation Complete"
echo "Your marketing automation stack is ready!"

cat <<EOT

🔗 Access your services:

  • Mautic:  https://$MAUTIC_HOST
     - Username: admin
     - Password: auto-generated on first run

  • N8N:     https://$N8N_HOST
     - Username: admin
     - Password: test1234#

To update your stack in future:
  docker compose pull
  docker compose up -d

Enjoy your self-hosted open-source stack 🎉

EOT
