#!/usr/bin/env bash
# Willow Inference Server Proxmox LXC creator (community-scripts style)
# Uses community-scripts build helpers; place this script alongside its paired
# installer under scripts/proxmox/install/willow-inference-server-install.sh.

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Willow-Inference-Server"
var_tags="${var_tags:-ai;audio;webrtc}"
var_cpu="${var_cpu:-8}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-80}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"   # required for Docker-in-LXC
var_keyctl="${var_keyctl:-1}"     # enable keyctl for Docker

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local branch="${WIS_BRANCH:-main}"

  if [[ ! -d /opt/willow-inference-server ]]; then
    msg_error "No ${APP} installation found in this container."
    exit 1
  fi

  msg_info "Stopping ${APP}"
  systemctl stop willow-inference-server.service >/dev/null 2>&1 || true

  msg_info "Updating ${APP} codebase"
  cd /opt/willow-inference-server || {
    msg_error "Unable to access /opt/willow-inference-server"
    exit 1
  }
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git fetch --quiet
    git checkout -q "$branch" || true
    git reset --hard "origin/${branch}" >/dev/null 2>&1
  fi

  msg_info "Rebuilding Docker image"
  ./utils.sh build >/dev/null 2>&1 || {
    msg_error "Failed to rebuild Docker image"
    exit 1
  }

  msg_info "Restarting service"
  systemctl start willow-inference-server.service >/dev/null 2>&1 || true
  msg_ok "Updated successfully!"
  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URLs:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP:-<container-ip>}:19000${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP:-<container-ip>}:19001${CL}"

