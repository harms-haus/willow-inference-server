#!/usr/bin/env bash
# Install Willow Inference Server inside a Proxmox LXC

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

set -euo pipefail

REPO_URL="https://github.com/toverainc/willow-inference-server.git"
REPO_BRANCH="${WIS_BRANCH:-main}"
REPO_DIR="/opt/willow-inference-server"
ENV_FILE="${REPO_DIR}/.env"
SERVICE_NAME="willow-inference-server.service"

ensure_env_var() {
  local key="$1"
  local value="$2"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    return 0
  fi
  echo "${key}=${value}" >>"$ENV_FILE"
}

msg_info "Installing base dependencies"
$STD apt-get install -y ca-certificates curl gnupg git lsb-release python3 python3-venv python3-pip ffmpeg
msg_ok "Installed base dependencies"

msg_info "Installing Docker Engine"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  >/etc/apt/sources.list.d/docker.list
$STD apt-get update
$STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
msg_ok "Installed Docker Engine"

GPU_MODE="cpu"
if command -v nvidia-smi >/dev/null 2>&1; then
  msg_info "Configuring NVIDIA Container Toolkit"
  distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg >/dev/null
  curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  $STD apt-get update
  $STD apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
  systemctl restart docker
  GPU_MODE="gpu"
  msg_ok "Configured NVIDIA runtime for Docker"
else
  msg_warn "NVIDIA GPU not detected - defaulting to CPU runtime"
fi

msg_info "Fetching Willow Inference Server"
if [ -d "${REPO_DIR}/.git" ]; then
  git -C "$REPO_DIR" fetch --quiet
  git -C "$REPO_DIR" checkout -q "$REPO_BRANCH"
  git -C "$REPO_DIR" reset --hard "origin/${REPO_BRANCH}" >/dev/null
else
  git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR" >/dev/null
fi
msg_ok "Repository ready"

msg_info "Creating default environment file"
ensure_env_var "IMAGE" "willow-inference-server"
ensure_env_var "TAG" "latest"
ensure_env_var "LISTEN_PORT_HTTPS" "19000"
ensure_env_var "LISTEN_PORT" "19001"
ensure_env_var "MEDIA_PORT_RANGE" "10000-10050"
ensure_env_var "SHM_SIZE" "1gb"
ensure_env_var "GPUS" "all"
ensure_env_var "FORWARDED_ALLOW_IPS" "127.0.0.1"
if [[ "$GPU_MODE" == "cpu" ]]; then
  ensure_env_var "FORCE_CPU" "1"
fi
msg_ok "Environment defaults written"

msg_info "Building image and downloading models (this can take a while)"
cd "$REPO_DIR"
./utils.sh install
msg_ok "Docker image built and models downloaded"

CERT_CN="${WIS_CERT_CN:-$(hostname -f 2>/dev/null || hostname)}"
msg_info "Generating TLS certificate for ${CERT_CN}"
./utils.sh gen-cert "$CERT_CN"
msg_ok "Generated TLS certificate"

COMPOSE_FILE_PATH="$REPO_DIR/docker-compose.yml"
if [[ "$GPU_MODE" == "cpu" ]]; then
  COMPOSE_FILE_PATH="$REPO_DIR/docker-compose-cpu.yml"
fi

msg_info "Creating systemd unit"
cat <<EOF >/etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Willow Inference Server
Requires=docker.service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
Environment=COMPOSE_FILE=${COMPOSE_FILE_PATH}
ExecStart=/usr/bin/env bash -lc 'cd ${REPO_DIR} && COMPOSE_FILE=${COMPOSE_FILE_PATH} ./utils.sh run -d'
ExecStop=/usr/bin/env bash -lc 'cd ${REPO_DIR} && COMPOSE_FILE=${COMPOSE_FILE_PATH} ./utils.sh down'
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now "$SERVICE_NAME"
msg_ok "Systemd unit created and started"

motd_ssh
customize
cleanup_lxc

