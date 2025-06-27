#!/bin/bash
set -e

echo "🧹 Cleaning up Docker stack and related resources..."

# Stop all containers and remove volumes/networks/images
docker compose down -v --remove-orphans || true
docker system prune -af --volumes

# Remove all containers and volumes (hard reset)
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume rm $(docker volume ls -q) 2>/dev/null || true
docker network rm $(docker network ls -q) 2>/dev/null || true

echo "🗑️ Removing Docker packages..."
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
apt-get autoremove -y

echo "🗃️ Deleting Docker folders..."
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
rm -rf /etc/apt/keyrings/docker.gpg
rm -rf /etc/apt/sources.list.d/docker.list

echo "✅ Cleanup complete. Server is now back to a clean state."
