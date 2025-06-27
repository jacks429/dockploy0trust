#!/usr/bin/env bash
set -euo pipefail

apt-get update -y
apt-get install -y jq curl

: "${DOKPLOY_API:?Environment variable DOKPLOY_API must be set (e.g. https://your-dokploy.example.com/api)}"
: "${DOKPLOY_BEARER_TOKEN:?Environment variable DOKPLOY_BEARER_TOKEN must be set}"

########################################
# Helpers for NetBird
########################################
NETBIRD_API_URL="${NETBIRD_MANAGEMENT_URL:-https://api.netbird.io}"

fetch_setup_key() {
    # 1) honour an existing key
    if [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
        echo "$NETBIRD_SETUP_KEY"
        return 0
    fi

    # 2) otherwise create / reuse via REST API
    if [ -z "${NETBIRD_API_TOKEN:-}" ]; then
        echo "NETBIRD_API_TOKEN not set; cannot auto-create setup-key" >&2
        exit 1
    fi

    local payload
    payload=$(
      jq -n --arg name "$(hostname)-dokploy" \
            '{name:$name,type:"reusable",expiresIn:0}'
    )

    curl -fsSL -H "Authorization: Bearer ${NETBIRD_API_TOKEN}" \
              -H "Content-Type: application/json"                \
              -d "$payload"                                      \
              "${NETBIRD_API_URL}/api/setup-keys" | jq -r '.key'
}

join_netbird() {
    if netbird status 2>&1 | grep -q 'Management: Connected'; then
        echo "NetBird already connected – skipping 'up'"
        return 0
    fi

    local key
    key="$(fetch_setup_key)"
    echo "Running: netbird up --setup-key ****"
    sudo netbird up --setup-key "$key"
}

########################################
# Helpers for Dokploy cluster API
########################################
join_dokploy() {
    echo "Fetching join command from Dokploy at $DOKPLOY_API"
    local cmd
    cmd=$(curl -fsSL \
      -H "Authorization: Bearer ${DOKPLOY_BEARER_TOKEN}" \
      "${DOKPLOY_API}/cluster.addWorker"
    )
    echo "Running Dokploy join command:"
    echo "  $cmd"
    eval "$cmd"
}

########################################
# NetBird installer
########################################
install_netbird() {
    if command -v netbird >/dev/null 2>&1; then
        echo "NetBird binary present – skipping install step"
    else
        echo "Installing NetBird headless…"
        export USE_BIN_INSTALL=true SKIP_UI_APP=true
        curl -fsSL https://pkgs.netbird.io/install.sh | bash
    fi

    sudo netbird service install || true
    sudo netbird service start   || true
    join_netbird
}


install_dokploy() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi
 
    # check if is Mac OS
    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi
 
    # check if is running inside a container
    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi
 
    # check if something is running on port 80
    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi
 
    # check if something is running on port 443
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi
 
    command_exists() {
      command -v "$@" > /dev/null 2>&1
    }
 
    if command_exists docker; then
      echo "Docker already installed"
    else
      curl -sSL https://get.docker.com | sh
    fi
 
    docker swarm leave --force 2>/dev/null
 
    get_ip() {
        local ip=""
        
        # Try IPv4 first
        # First attempt: ifconfig.io
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        
        # Second attempt: icanhazip.com
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        
        # Third attempt: ipecho.net
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi
 
        # If no IPv4, try IPv6
        if [ -z "$ip" ]; then
            # Try IPv6 with ifconfig.io
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
            
            # Try IPv6 with icanhazip.com
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
            fi
            
            # Try IPv6 with ipecho.net
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
            fi
        fi
 
        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically (neither IPv4 nor IPv6)." >&2
            echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
            echo "Example: export ADVERTISE_ADDR=<your-server-ip>" >&2
            exit 1
        fi
 
        echo "$ip"
    }
 
    advertise_addr="${ADVERTISE_ADDR:-$(get_ip)}"
    echo "Using advertise address: $advertise_addr"
 
    docker swarm init --advertise-addr $advertise_addr
    
     if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    fi
 
    echo "Swarm initialized"
 
    docker network rm -f dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network
 
    echo "Network created"
 
    mkdir -p /etc/dokploy
 
    chmod 777 /etc/dokploy
 
    docker service create \
    --name dokploy-postgres \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --env POSTGRES_USER=dokploy \
    --env POSTGRES_DB=dokploy \
    --env POSTGRES_PASSWORD=amukds4wi9001583845717ad2 \
    --mount type=volume,source=dokploy-postgres-database,target=/var/lib/postgresql/data \
    postgres:16
 
    docker service create \
    --name dokploy-redis \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --mount type=volume,source=redis-data-volume,target=/data \
    redis:7
 
    docker pull traefik:v3.1.2
    docker pull dokploy/dokploy:latest
 
    # Installation
    docker service create \
      --name dokploy \
      --replicas 1 \
      --network dokploy-network \
      --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
      --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
      --mount type=volume,source=dokploy-docker-config,target=/root/.docker \
      --publish published=3000,target=3000,mode=host \
      --update-parallelism 1 \
      --update-order stop-first \
      --constraint 'node.role == manager' \
      -e ADVERTISE_ADDR=$advertise_addr \
      dokploy/dokploy:latest
 
 
    docker run -d \
        --name dokploy-traefik \
        --network dokploy-network \
        --restart always \
        -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
        -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -p 80:80/tcp \
        -p 443:443/tcp \
        -p 443:443/udp \
        traefik:v3.1.2
 
 
    # Optional: Use docker service create instead of docker run
    #   docker service create \
    #     --name dokploy-traefik \
    #     --constraint 'node.role==manager' \
    #     --network dokploy-network \
    #     --mount type=bind,source=/etc/dokploy/traefik/traefik.yml,target=/etc/traefik/traefik.yml \
    #     --mount type=bind,source=/etc/dokploy/traefik/dynamic,target=/etc/dokploy/traefik/dynamic \
    #     --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    #     --publish mode=host,published=443,target=443 \
    #     --publish mode=host,published=80,target=80 \
    #     --publish mode=host,published=443,target=443,protocol=udp \
    #     traefik:v3.1.2
 
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m" # No Color
 
    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            # IPv6
            echo "[${ip}]"
        else
            # IPv4
            echo "${ip}"
        fi
    }
 
    formatted_addr=$(format_ip_for_url "$advertise_addr")
    echo ""
    printf "${GREEN}Congratulations, Dokploy is installed!${NC}\n"
    printf "${BLUE}Wait 15 seconds for the server to start${NC}\n"
    printf "${YELLOW}Please go to http://${formatted_addr}:3000${NC}\n\n"
}
 
update_dokploy() {
    echo "Updating Dokploy..."
    
    # Pull the latest image
    docker pull dokploy/dokploy:latest
 
    # Update the service
    docker service update --image dokploy/dokploy:latest dokploy
 
    echo "Dokploy has been updated to the latest version."
}
 

########################################
# Main entry-point
########################################
case "${1:-}" in
  worker)
    install_netbird
    join_dokploy
    ;;
  update)
    update_dokploy
    ;;
  *)
    install_netbird
    install_dokploy
    ;;
esac