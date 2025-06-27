#!/usr/bin/env bash
exec > >(tee /var/log/bootstrap.log) 2>&1
set -euo pipefail

apt-get update
apt-get install -y jq curl

export DOKPLOY_API="${dokApi}"
export DOKPLOY_API_KEY="${dokToken}"
export NETBIRD_API_TOKEN="${nbToken}"
export NETBIRD_MANAGEMENT_URL="${nbApiUrl}"

# Helpers

NETBIRD_API_URL="\${NETBIRD_MANAGEMENT_URL:-https://api.netbird.io}"

fetch_setup_key() {
  if [ -n "\${NETBIRD_SETUP_KEY:-}" ]; then
    echo "\$NETBIRD_SETUP_KEY"
    return 0
  fi

  if [ -z "\${NETBIRD_API_TOKEN:-}" ]; then
    echo "NETBIRD_API_TOKEN not set; cannot auto-create setup-key" >&2
    exit 1
  fi

  local payload
  payload=\$(
    jq -n --arg name "\$(hostname)-dokdeploy" '{name:$name,type:"reusable",expiresIn:0}'
  )

  curl -fsSL \
    -H "Authorization: Bearer \${NETBIRD_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "\$payload" \
    "\${NETBIRD_API_URL}/api/setup-keys" \
    | jq -r '.key'
}

join_netbird() {
  if netbird status 2>&1 | grep -q 'Management: Connected'; then
    echo "NetBird already connected – skipping 'up'"
    return 0
  fi

  local key
  key="\$(fetch_setup_key)"
  echo "Running: netbird up --setup-key ****"
  sudo netbird up --setup-key "\$key"
}

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

install_docker() {
  echo "Installing Docker…"
  curl -fsSL https://get.docker.com | sh -s -- --version 28.2.2
}

join_dokploy() {
  echo "Fetching join command from Dokploy at \$DOKPLOY_API"
  # 1) get the raw join command
  local raw_cmd
  raw_cmd=\$(
    curl -fsSL -X GET \
      -H "accept: application/json" \
      -H "x-api-key: \$DOKPLOY_API_KEY" \
      "\$DOKPLOY_API/cluster.addWorker" \
      | jq -r '.command'
  )

  # 2) derive dok host (strip https:// and path)
  local dok_host
  dok_host="\${DOKPLOY_API#https://}"
  dok_host="\${dok_host%%/*}:2377"

  # 3) replace IP:PORT with dok_host:2377
  local join_cmd
  join_cmd=\$(echo "\$raw_cmd" \
    | sed -E "s#[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:2377#\${dok_host}#g"
  )

  echo "Running Dokploy join command:"
  echo "  \$join_cmd"
  eval "\$join_cmd"
}

# ─── bootstrap ─────────────────────────────────────────────────
install_netbird
install_docker
join_dokploy
