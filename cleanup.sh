#!/bin/bash
set -e

RESET_DB=false

# Parse optional --reset flag
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --reset) RESET_DB=true ;;
  esac
  shift
done

echo "🧹 Cleaning up Docker stack and related resources..."

docker compose down -v --remove-orphans || true
docker system prune -af --volumes

if [ "$RESET_DB" = true ]; then
  read -p "⚠️ Are you sure you want to REMOVE the specific Docker volumes (mautic-n8n-stack_db_data, n8n_data)? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Removing volumes..."
    docker volume rm mautic-n8n-stack_db_data n8n_data || true
  else
    echo "Volume removal cancelled."
  fi
fi

read -p "⚠️ Are you sure you want to REMOVE all containers, volumes, networks, and Docker packages? [y/N] " confirm_all
if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
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
else
  echo "Cleanup aborted by user."
fi
