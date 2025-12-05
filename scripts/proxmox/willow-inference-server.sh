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
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"   # required for Docker-in-LXC
var_keyctl="${var_keyctl:-1}"     # enable keyctl for Docker
INSTALL_BASE="https://raw.githubusercontent.com/harms-haus/willow-inference-server/main/scripts/proxmox/install"

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

# Override build_container to fetch installer from harms-haus instead of community-scripts
build_container() {
  NET_STRING="-net0 name=eth0,bridge=${BRG:-vmbr0}"

  [[ -n "$MAC" ]] && NET_STRING+=",hwaddr=${MAC#,hwaddr=}"
  NET_STRING+=",ip=${NET:-dhcp}"
  [[ -n "$GATE" ]] && NET_STRING+=",gw=${GATE#,gw=}"
  [[ -n "$VLAN" ]] && NET_STRING+=",tag=${VLAN#,tag=}"
  [[ -n "$MTU" ]] && NET_STRING+=",mtu=${MTU#,mtu=}"

  case "$IPV6_METHOD" in
  auto) NET_STRING="$NET_STRING,ip6=auto" ;;
  dhcp) NET_STRING="$NET_STRING,ip6=dhcp" ;;
  static)
    NET_STRING="$NET_STRING,ip6=$IPV6_ADDR"
    [ -n "$IPV6_GATE" ] && NET_STRING="$NET_STRING,gw6=$IPV6_GATE"
    ;;
  none) ;;
  esac

  if [ "$CT_TYPE" == "1" ]; then
    FEATURES="keyctl=1,nesting=1"
  else
    FEATURES="nesting=1"
  fi
  [ "$ENABLE_FUSE" == "yes" ] && FEATURES="$FEATURES,fuse=1"

  TEMP_DIR=$(mktemp -d)
  pushd "$TEMP_DIR" >/dev/null
  if [ "$var_os" == "alpine" ]; then
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/alpine-install.func)"
  else
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"
  fi

  export DIAGNOSTICS="$DIAGNOSTICS"
  export RANDOM_UUID="$RANDOM_UUID"
  export SESSION_ID="$SESSION_ID"
  export CACHER="$APT_CACHER"
  export CACHER_IP="$APT_CACHER_IP"
  export tz="$timezone"
  export APPLICATION="$APP"
  export app="$NSAPP"
  export PASSWORD="$PW"
  export VERBOSE="$VERBOSE"
  export SSH_ROOT="${SSH}"
  export SSH_AUTHORIZED_KEY
  export CTID="$CT_ID"
  export CTTYPE="$CT_TYPE"
  export ENABLE_FUSE="$ENABLE_FUSE"
  export ENABLE_TUN="$ENABLE_TUN"
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="$var_version"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export BUILD_LOG="$BUILD_LOG"
  export INSTALL_LOG="/root/.install-${SESSION_ID}.log"
  export dev_mode="${dev_mode:-}"
  export DEV_MODE_MOTD="${DEV_MODE_MOTD:-false}"
  export DEV_MODE_KEEP="${DEV_MODE_KEEP:-false}"
  export DEV_MODE_TRACE="${DEV_MODE_TRACE:-false}"
  export DEV_MODE_PAUSE="${DEV_MODE_PAUSE:-false}"
  export DEV_MODE_BREAKPOINT="${DEV_MODE_BREAKPOINT:-false}"
  export DEV_MODE_LOGS="${DEV_MODE_LOGS:-false}"
  export DEV_MODE_DRYRUN="${DEV_MODE_DRYRUN:-false}"

  PCT_OPTIONS_STRING="  -features $FEATURES
  -hostname $HN
  -tags $TAGS"

  [ -n "$SD" ] && PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  $SD"
  [ -n "$NS" ] && PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  $NS"

  PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  $NET_STRING
  -onboot 1
  -cores $CORE_COUNT
  -memory $RAM_SIZE
  -unprivileged $CT_TYPE"

  if [ "${PROTECT_CT:-}" = "1" ] || [ "${PROTECT_CT:-}" = "yes" ]; then
    PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  -protection 1"
  fi

  [ -n "${CT_TIMEZONE:-}" ] && PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  -timezone $CT_TIMEZONE"
  [ -n "$PW" ] && PCT_OPTIONS_STRING="$PCT_OPTIONS_STRING
  $PW"

  export PCT_OPTIONS="$PCT_OPTIONS_STRING"
  export TEMPLATE_STORAGE="${var_template_storage:-}"
  export CONTAINER_STORAGE="${var_container_storage:-}"

  create_lxc_container || exit $?
  LXC_CONFIG="/etc/pve/lxc/${CTID}.conf"

  GPU_APPS=(immich channels emby ersatztv frigate jellyfin plex scrypted tdarr unmanic ollama fileflows open-webui tunarr debian handbrake sunshine moonlight kodi stremio viseron)

  is_gpu_app() {
    local app="${1,,}"
    for gpu_app in "${GPU_APPS[@]}"; do
      [[ "$app" == "${gpu_app,,}" ]] && return 0
    done
    return 1
  }

  detect_gpu_devices() {
    INTEL_DEVICES=()
    AMD_DEVICES=()
    NVIDIA_DEVICES=()
    local pci_vga_info
    pci_vga_info=$(lspci -nn 2>/dev/null | grep -E "VGA|Display|3D")
    if echo "$pci_vga_info" | grep -q "\[8086:"; then
      msg_custom "🎮" "${BL}" "Detected Intel GPU"
      if [[ -d /dev/dri ]]; then
        for d in /dev/dri/renderD* /dev/dri/card*; do [[ -e "$d" ]] && INTEL_DEVICES+=("$d"); done
      fi
    fi
    if echo "$pci_vga_info" | grep -qE "\[1002:|\[1022:"; then
      msg_custom "🎮" "${RD}" "Detected AMD GPU"
      if [[ -d /dev/dri && ${#INTEL_DEVICES[@]} -eq 0 ]]; then
        for d in /dev/dri/renderD* /dev/dri/card*; do [[ -e "$d" ]] && AMD_DEVICES+=("$d"); done
      fi
    fi
    if echo "$pci_vga_info" | grep -q "\[10de:"; then
      msg_custom "🎮" "${GN}" "Detected NVIDIA GPU"
      for d in /dev/nvidia* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do [[ -e "$d" ]] && NVIDIA_DEVICES+=("$d"); done
      if [[ ${#NVIDIA_DEVICES[@]} -gt 0 ]]; then
        msg_custom "🎮" "${GN}" "Found ${#NVIDIA_DEVICES[@]} NVIDIA device(s) for passthrough"
      else
        msg_warn "NVIDIA GPU detected via PCI but no /dev/nvidia* devices found"
        msg_custom "ℹ️" "${YW}" "Skipping NVIDIA passthrough (host drivers may not be loaded)"
      fi
    fi
    msg_debug "Intel devices: ${INTEL_DEVICES[*]}"
    msg_debug "AMD devices: ${AMD_DEVICES[*]}"
    msg_debug "NVIDIA devices: ${NVIDIA_DEVICES[*]}"
  }

  configure_usb_passthrough() {
    if [[ "$CT_TYPE" != "0" ]]; then return 0; fi
    msg_info "Configuring automatic USB passthrough (privileged container)"
    cat <<EOF >>"$LXC_CONFIG"
# Automatic USB passthrough (privileged container)
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.cgroup2.devices.allow: c 188:* rwm
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/serial/by-id  dev/serial/by-id  none bind,optional,create=dir
lxc.mount.entry: /dev/ttyUSB0       dev/ttyUSB0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyUSB1       dev/ttyUSB1       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM0       dev/ttyACM0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM1       dev/ttyACM1       none bind,optional,create=file
EOF
    msg_ok "USB passthrough configured"
  }

  configure_gpu_passthrough() {
    if [[ "$CT_TYPE" != "0" ]] && ! is_gpu_app "$APP"; then return 0; fi
    detect_gpu_devices
    local gpu_count=0 available_gpus=()
    [[ ${#INTEL_DEVICES[@]} -gt 0 ]] && available_gpus+=("INTEL") && gpu_count=$((gpu_count + 1))
    [[ ${#AMD_DEVICES[@]} -gt 0 ]] && available_gpus+=("AMD") && gpu_count=$((gpu_count + 1))
    [[ ${#NVIDIA_DEVICES[@]} -gt 0 ]] && available_gpus+=("NVIDIA") && gpu_count=$((gpu_count + 1))
    if [[ $gpu_count -eq 0 ]]; then
      msg_custom "ℹ️" "${YW}" "No GPU devices found for passthrough"
      return 0
    fi
    local selected_gpu=""
    if [[ $gpu_count -eq 1 ]]; then
      selected_gpu="${available_gpus[0]}"
      msg_ok "Automatically configuring ${selected_gpu} GPU passthrough"
    else
      echo -e "\n${INFO} Multiple GPU types detected:"
      for gpu in "${available_gpus[@]}"; do echo "  - $gpu"; done
      read -rp "Which GPU type to passthrough? (${available_gpus[*]}): " selected_gpu
      selected_gpu="${selected_gpu^^}"
      local valid=0
      for gpu in "${available_gpus[@]}"; do [[ "$selected_gpu" == "$gpu" ]] && valid=1; done
      if [[ $valid -eq 0 ]]; then
        msg_warn "Invalid selection. Skipping GPU passthrough."
        return 0
      fi
    fi
    case "$selected_gpu" in
    INTEL | AMD)
      local devices=()
      [[ "$selected_gpu" == "INTEL" ]] && devices=("${INTEL_DEVICES[@]}")
      [[ "$selected_gpu" == "AMD" ]] && devices=("${AMD_DEVICES[@]}")
      local dev_index=0
      for dev in "${devices[@]}"; do echo "dev${dev_index}: ${dev},gid=44" >>"$LXC_CONFIG"; dev_index=$((dev_index + 1)); done
      export GPU_TYPE="$selected_gpu"
      msg_ok "${selected_gpu} GPU passthrough configured (${#devices[@]} devices)"
      ;;
    NVIDIA)
      if [[ ${#NVIDIA_DEVICES[@]} -eq 0 ]]; then
        msg_warn "No NVIDIA devices available for passthrough"
        return 0
      fi
      local dev_index=0
      for dev in "${NVIDIA_DEVICES[@]}"; do echo "dev${dev_index}: ${dev},gid=44" >>"$LXC_CONFIG"; dev_index=$((dev_index + 1)); done
      export GPU_TYPE="NVIDIA"
      msg_ok "NVIDIA GPU passthrough configured (${#NVIDIA_DEVICES[@]} devices) - install drivers in container if needed"
      ;;
    esac
  }

  configure_additional_devices() {
    if [ "$ENABLE_TUN" == "yes" ]; then
      cat <<EOF >>"$LXC_CONFIG"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
    fi
    if [[ -e /dev/apex_0 ]]; then
      msg_custom "🔌" "${BL}" "Detected Coral TPU - configuring passthrough"
      echo "lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file" >>"$LXC_CONFIG"
    fi
  }

  configure_usb_passthrough
  configure_gpu_passthrough
  configure_additional_devices

  msg_info "Starting LXC Container"
  pct start "$CTID"
  for i in {1..10}; do
    if pct status "$CTID" | grep -q "status: running"; then
      msg_ok "Started LXC Container"
      break
    fi
    sleep 1
    if [ "$i" -eq 10 ]; then
      msg_error "LXC Container did not reach running state"
      exit 1
    fi
  done

  if [ "$var_os" != "alpine" ]; then
    msg_info "Waiting for network in LXC container"
    local ip_in_lxc=""
    for i in {1..20}; do
      ip_in_lxc=$(pct exec "$CTID" -- ip -4 addr show dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
      if [ -z "$ip_in_lxc" ]; then
        ip_in_lxc=$(pct exec "$CTID" -- ip -6 addr show dev eth0 scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n1)
      fi
      [ -n "$ip_in_lxc" ] && break
      sleep 1
    done
    if [ -z "$ip_in_lxc" ]; then
      msg_error "No IP assigned to CT $CTID after 20s"
      echo -e "${YW}Troubleshooting:${CL}"
      echo "  • Verify bridge ${BRG} exists and has connectivity"
      echo "  • Check DHCP/static configuration"
      echo "  • Check Proxmox firewall rules"
      echo "  • If using Tailscale: Disable MagicDNS temporarily"
      exit 1
    fi
    local ping_success=false
    for retry in {1..3}; do
      if pct exec "$CTID" -- ping -c 1 -W 2 1.1.1.1 &>/dev/null ||
        pct exec "$CTID" -- ping -c 1 -W 2 8.8.8.8 &>/dev/null ||
        pct exec "$CTID" -- ping6 -c 1 -W 2 2606:4700:4700::1111 &>/dev/null; then
        ping_success=true
        break
      fi
      sleep 2
    done
    if [ "$ping_success" = false ]; then
      msg_warn "Network configured (IP: $ip_in_lxc) but connectivity test failed"
      echo -e "${YW}Container may have limited internet access. Installation will continue...${CL}"
    else
      msg_ok "Network in LXC is reachable (ping)"
    fi
  fi

  fix_gpu_gids

  msg_info "Customizing LXC Container"
  if [ "$var_os" == "alpine" ]; then
    sleep 3
    pct exec "$CTID" -- /bin/sh -c 'cat <<EOF >/etc/apk/repositories
http://dl-cdn.alpinelinux.org/alpine/latest-stable/main
http://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF'
    pct exec "$CTID" -- ash -c "apk add bash newt curl openssh nano mc ncurses jq >/dev/null"
  else
    sleep 3
    pct exec "$CTID" -- bash -c "sed -i '/$LANG/ s/^# //' /etc/locale.gen"
    pct exec "$CTID" -- bash -c "locale_line=\$(grep -v '^#' /etc/locale.gen | grep -E '^[a-zA-Z]' | awk '{print \$1}' | head -n 1) && echo LANG=\$locale_line >/etc/default/locale && locale-gen >/dev/null && export LANG=\$locale_line"
    if [[ -z "${tz:-}" ]]; then
      tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
    fi
    if pct exec "$CTID" -- test -e "/usr/share/zoneinfo/$tz"; then
      pct exec "$CTID" -- bash -c "tz='$tz'; ln -sf \"/usr/share/zoneinfo/\$tz\" /etc/localtime && echo \"\$tz\" >/etc/timezone || true"
    else
      msg_warn "Skipping timezone setup – zone '$tz' not found in container"
    fi
    pct exec "$CTID" -- bash -c "apt-get update >/dev/null && apt-get install -y sudo curl mc gnupg2 jq >/dev/null" || {
      msg_error "apt-get base packages installation failed"
      exit 1
    }
  fi
  msg_ok "Customized LXC Container"

  install_ssh_keys_into_ct

  set +Eeuo pipefail
  trap - ERR
  lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL ${INSTALL_BASE}/${var_install}.sh)"
  local lxc_exit=$?
  set -Eeuo pipefail
  trap 'error_handler' ERR

  local install_exit_code=0
  if [[ -n "${SESSION_ID:-}" ]]; then
    local error_flag="/root/.install-${SESSION_ID}.failed"
    if pct exec "$CTID" -- test -f "$error_flag" 2>/dev/null; then
      install_exit_code=$(pct exec "$CTID" -- cat "$error_flag" 2>/dev/null || echo "1")
      pct exec "$CTID" -- rm -f "$error_flag" 2>/dev/null || true
    fi
  fi
  if [[ $install_exit_code -eq 0 && $lxc_exit -ne 0 ]]; then
    install_exit_code=$lxc_exit
  fi

  if [[ $install_exit_code -ne 0 ]]; then
    msg_error "Installation failed in container ${CTID} (exit code: ${install_exit_code})"
    local build_log_copied=false
    local install_log_copied=false
    if [[ -n "$CTID" && -n "${SESSION_ID:-}" ]]; then
      if [[ -f "${BUILD_LOG}" ]]; then
        cp "${BUILD_LOG}" "/tmp/create-lxc-${CTID}-${SESSION_ID}.log" 2>/dev/null && build_log_copied=true
      fi
      if pct pull "$CTID" "/root/.install-${SESSION_ID}.log" "/tmp/install-lxc-${CTID}-${SESSION_ID}.log" 2>/dev/null; then
        install_log_copied=true
      fi
      echo ""
      [[ "$build_log_copied" == true ]] && echo -e "${GN}✔${CL} Container creation log: ${BL}/tmp/create-lxc-${CTID}-${SESSION_ID}.log${CL}"
      [[ "$install_log_copied" == true ]] && echo -e "${GN}✔${CL} Installation log: ${BL}/tmp/install-lxc-${CTID}-${SESSION_ID}.log${CL}"
    fi

    if [[ "${DEV_MODE_KEEP:-false}" == "true" ]]; then
      msg_dev "Keep mode active - container ${CTID} preserved"
      return 0
    elif [[ "${DEV_MODE_BREAKPOINT:-false}" == "true" ]]; then
      msg_dev "Breakpoint mode - opening shell in container ${CTID}"
      echo -e "${YW}Type 'exit' to return to host${CL}"
      pct enter "$CTID"
      echo ""
      echo -en "${YW}Container ${CTID} still running. Remove now? (y/N): ${CL}"
      if read -r response && [[ "$response" =~ ^[Yy]$ ]]; then
        pct stop "$CTID" &>/dev/null || true
        pct destroy "$CTID" &>/dev/null || true
        msg_ok "Container ${CTID} removed"
      else
        msg_dev "Container ${CTID} kept for debugging"
      fi
      exit $install_exit_code
    fi

    echo ""
    echo -en "${YW}Remove broken container ${CTID}? (Y/n) [auto-remove in 60s]: ${CL}"
    if read -t 60 -r response; then
      if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
        echo -e "\n${TAB}${HOLD}${YW}Removing container ${CTID}${CL}"
        pct stop "$CTID" &>/dev/null || true
        pct destroy "$CTID" &>/dev/null || true
        echo -e "${BFR}${CM}${GN}Container ${CTID} removed${CL}"
      elif [[ "$response" =~ ^[Nn]$ ]]; then
        echo -e "\n${TAB}${YW}Container ${CTID} kept for debugging${CL}"
        if [[ "${DEV_MODE_MOTD:-false}" == "true" ]]; then
          echo -e "${TAB}${HOLD}${DGN}Setting up MOTD and SSH for debugging...${CL}"
          if pct exec "$CTID" -- bash -c "
            source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)
            declare -f motd_ssh >/dev/null 2>&1 && motd_ssh || true
          " >/dev/null 2>&1; then
            local ct_ip
            ct_ip=$(pct exec "$CTID" ip a s dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
            echo -e "${BFR}${CM}${GN}MOTD/SSH ready - SSH into container: ssh root@${ct_ip}${CL}"
          fi
        fi
      fi
    else
      echo -e "\n${YW}No response - auto-removing container${CL}"
      echo -e "${TAB}${HOLD}${YW}Removing container ${CTID}${CL}"
      pct stop "$CTID" &>/dev/null || true
      pct destroy "$CTID" &>/dev/null || true
      echo -e "${BFR}${CM}${GN}Container ${CTID} removed${CL}"
    fi
    exit $install_exit_code
  fi
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URLs:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP:-<container-ip>}:19000${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP:-<container-ip>}:19001${CL}"

