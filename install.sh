#!/bin/bash
set -e

# ------------------ Docker Installation ------------------

install_docker() {
    echo "🔧 Docker not found. Installing Docker & Docker Compose..."

    apt-get update && apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        dnsutils

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

# ------------------ Argument Parsing ------------------

DOMAIN=""
EMAIL=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift ;;
        --email) EMAIL="$2"; shift ;;
        *) echo "❌ Unknown parameter passed: $1" ; exit 1 ;;
    esac
    shift
done

[[ -z "$DOMAIN" ]] && { echo "❌ --domain is required"; exit 1; }
[[ -z "$EMAIL" ]] && { echo "❌ --email is required"; exit 1; }

# ------------------ Prompt for Subdomains ------------------

echo -e "\n📛 Subdomain Configuration"
read -p "Enter subdomain for Mautic (default: m): " MAUTIC_SUB
read -p "Enter subdomain for N8N (default: n8n): " N8N_SUB

# Fallback to defaults
MAUTIC_SUB="${MAUTIC_SUB:-m}"
N8N_SUB="${N8N_SUB:-n8n}"

MAUTIC_HOST="$MAUTIC_SUB.$DOMAIN"
N8N_HOST="$N8N_SUB.$DOMAIN"

# ------------------ DNS Propagation Check ------------------

resolve_ip() {
    dig +short "$1" @8.8.8.8 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

PUBLIC_IP=$(curl -s https://api.ipify.org)

echo -e "\n🔧 Please create the following DNS A records pointing to your server IP:"
echo "  - $MAUTIC_HOST ➜ $PUBLIC_IP"
echo "  - $N8N_HOST    ➜ $PUBLIC_IP"

echo -e "\n⏳ Waiting for DNS propagation (CTRL+C to cancel)..."

MAX_RETRIES=20
SLEEP_INTERVAL=30
RETRY=0

while (( RETRY < MAX_RETRIES )); do
    MAUTIC_IP=$(resolve_ip "$MAUTIC_HOST")
    N8N_IP=$(resolve_ip "$N8N_HOST")

    echo -e "\nDNS Check:"
    echo -n "  $MAUTIC_HOST ➜ $MAUTIC_IP "; [[ "$MAUTIC_IP" == "$PUBLIC_IP" ]] && echo "✅" || echo "❌"
    echo -n "  $N8N_HOST    ➜ $N8N_IP "; [[ "$N8N_IP" == "$PUBLIC_IP" ]] && echo "✅" || echo "❌"

    if [[ "$MAUTIC_IP" == "$PUBLIC_IP" && "$N8N_IP" == "$PUBLIC_IP" ]]; then
        echo "✅ DNS records are correctly propagated."
        break
    fi

    (( RETRY++ ))
    echo "🔁 Retrying in $SLEEP_INTERVAL seconds… ($RETRY/$MAX_RETRIES)"
    sleep $SLEEP_INTERVAL
done

if (( RETRY == MAX_RETRIES )); then
    echo "❌ DNS did not propagate within expected time. Please check your A records."
    exit 1
fi

# ------------------ Docker Compose Stack Setup ------------------

echo -e "\n⚙️ Setting up Docker Compose Stack..."

mkdir -p mautic-n8n-stack && cd mautic-n8n-stack

mkdir -p letsencrypt

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

# ------------------ Launch Stack ------------------

echo -e "\n🚀 Launching your stack..."
docker compose up -d

echo -e "\n✅ Installation Complete!"
cat <<EOT

🔗 Access your services:

  • Mautic:  https://$MAUTIC_HOST
     - Username: admin
     - Password: (set during initial setup)

  • N8N:     https://$N8N_HOST
     - Username: admin
     - Password: test1234#

To update your stack in future:
  docker compose pull
  docker compose up -d

✨ Enjoy your self-hosted automation stack!
EOT
