#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log_info(){ printf "[INFO] %s\n" "$*"; }
log_warn(){ printf "[WARN] %s\n" "$*"; }
log_section(){ printf "\n[====] %s\n" "$*"; }
log_task_start(){ printf "[INFO] ▶ %s\n" "$*"; }
log_task_done(){ printf "[INFO] ✓ %s\n" "$*"; }

# Re-run under sudo for system tasks
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
USER_HOME="$(eval echo ~${TARGET_USER})"

# -----------------------
# Shared helpers
# -----------------------

# Determine user + home when called after mutations.
refresh_target_context(){
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  USER_HOME="$(eval echo ~${TARGET_USER})"
}

# Run a command as the target desktop user.
run_as_target_user(){
  local cmd="$1"
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "${TARGET_USER}" bash -lc "$cmd"
  else
    bash -lc "$cmd"
  fi
}

# Download a file with curl or wget while keeping flags configurable.
download_file(){
  local url="$1" dest="$2" curl_opts="${3:--fsSL}" wget_opts="${4:--qO}"
  if command -v curl >/dev/null 2>&1; then
    curl ${curl_opts} "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget ${wget_opts} "$dest" "$url"
  else
    return 1
  fi
}

# Secure a sudoers drop-in file and restore on visudo failure.
secure_sudoers_file(){
  local f="$1"
  [ -n "$f" ] && [ -e "$f" ] || return 1
  local BACKUP="${f}.bak.$(date +%s)"
  cp -a "$f" "$BACKUP" 2>/dev/null || true
  chown root:root "$f" 2>/dev/null || true
  chmod 0440 "$f" 2>/dev/null || true
  visudo -c -f "$f" >/dev/null 2>&1 || {
    log_warn "visudo failed for $f; restoring"
    [ -f "$BACKUP" ] && mv -f "$BACKUP" "$f"
    return 1
  }
}

# Correct sudoers.d ownership for non-root files.
fix_sudoers_ownership(){
  [ -d /etc/sudoers.d ] || return 0
  for f in /etc/sudoers.d/*; do
    [ -e "$f" ] || continue
    uid=$(stat -c %u "$f" 2>/dev/null || echo)
    [ "$uid" = "0" ] && continue
    log_warn "fixing owner for $f (uid=$uid)"
    secure_sudoers_file "$f" || log_warn "secure_sudoers_file failed for $f"
  done
}

# Write a passwordless sudo drop-in for the target user.
configure_passwordless_sudo(){
  local T="${TARGET_USER}"
  [ -n "$T" ] || return 0
  local FILE="/etc/sudoers.d/${T}_nopasswd"
  printf '%s\n' "${T} ALL=(ALL) NOPASSWD:ALL" > "/tmp/$$.sudoers"
  mv -f "/tmp/$$.sudoers" "${FILE}"
  chown root:root "${FILE}" 2>/dev/null || true
  chmod 0440 "${FILE}" 2>/dev/null || true
  log_info "passwordless sudo written for ${T}"
}

# Attempt to repair dpkg state with force-overwrite.
attempt_fix_broken_with_force_overwrite(){
  apt-get -o Dpkg::Options::="--force-overwrite" --fix-broken install -y || {
    dpkg --configure -a || true
    apt-get -o Dpkg::Options::="--force-overwrite" --fix-broken install -y || return 1
  }
}

# Bring in VM tools early to prevent display issues.
early_install_vm_tools(){
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y 'open-vm-tools*' >/dev/null 2>&1 || true
}

# -----------------------
# Package & system tasks
# -----------------------

# Configure apt/needrestart to avoid prompts during upgrades.
configure_noninteractive_apt(){
  log_task_start "configure_noninteractive_apt"
  set -e
  sudo mkdir -p /etc/apt/apt.conf.d
  printf '%s\n' 'Dpkg::Options{ "--force-confdef"; "--force-confold"; };' \
  | sudo tee /etc/apt/apt.conf.d/90force-conf >/dev/null

  sudo mkdir -p /etc/needrestart/conf.d
  printf '%s\n' '$nrconf{restart} = "a";' '$nrconf{kernelhints} = 0;' \
  | sudo tee /etc/needrestart/conf.d/zzz-auto-restart.conf >/dev/null

  log_task_done "configure_noninteractive_apt"
}

# Run apt update/upgrade with recovery attempts.
update_and_upgrade_apt(){
  log_task_start "apt update & upgrade"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || log_warn "apt update failed"
  apt-get -y upgrade || { log_warn "apt upgrade failed; attempting recovery"; attempt_fix_broken_with_force_overwrite || log_warn "fix-broken failed"; }
  apt-get -y autoremove || true
  apt-get -y autoclean || true
  log_task_done "apt update & upgrade"
}

# Install the core kali packages used everywhere.
install_core_packages(){
  log_task_start "install_core_packages"
  PACKAGES=(build-essential git curl wget vim tmux htop jq unzip zip apt-transport-https ca-certificates gnupg python3 python3-pip python3-venv python3-dev python-is-python3 python3-virtualenv nmap net-tools tcpdump aircrack-ng hashcat john hydra sqlmap impacket-scripts nikto metasploit-framework burpsuite docker.io docker-compose openvpn wireshark remmina remmina-common remmina-dev gdebi)
  apt-get update || log_warn "apt-get update failed"
  if apt-get install -y "${PACKAGES[@]}"; then
    log_info "install_core_packages: packages installed"
  else
    log_warn "install_core_packages: initial install failed; attempting recovery"
    attempt_fix_broken_with_force_overwrite || log_warn "attempt_fix_broken failed"
    if apt-get install -y "${PACKAGES[@]}"; then
      log_info "install_core_packages: packages installed on retry"
    else
      log_warn "install_core_packages: install still failed after retry"
    fi
  fi
  log_task_done "install_core_packages"
}

# Enable docker service and add user to the group.
configure_docker(){
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || log_warn "docker enable/start failed"
    usermod -aG docker "${SUDO_USER:-${TARGET_USER}}" 2>/dev/null || true
    log_task_done "configure_docker"
  fi
}

# Ensure an ed25519 SSH key exists for the target user.
ensure_ssh_key(){
  log_task_start "ensure_ssh_key"
  local SSH_PRI="${USER_HOME}/.ssh/id_ed25519"
  if [ ! -f "${SSH_PRI}" ]; then
    run_as_target_user "mkdir -p '$(dirname "${SSH_PRI}")'"
    run_as_target_user "ssh-keygen -t ed25519 -a 100 -f '${SSH_PRI}' -N '' -C '${TARGET_USER}@$(hostname -s)'" >/dev/null 2>&1 || log_warn "ssh-keygen failed"
    log_info "Generated SSH key for ${TARGET_USER}"
  else
    log_info "SSH key exists"
  fi
  log_task_done "ensure_ssh_key"
}

# Install pipx and ensure it is on PATH for the user.
ensure_python_tools(){
  log_task_start "ensure_python_tools (pipx)"
  apt-get install -y pipx python3-pip >/dev/null 2>&1 || true
  run_as_target_user 'python3 -m pip install --user pipx >/dev/null 2>&1 || true; python3 -m pipx ensurepath >/dev/null 2>&1 || true' || true
  log_task_done "ensure_python_tools (pipx)"
}

# Bring in Ubuntu Mono fonts and rebuild the cache.
install_ubuntu_mono_fontset(){
  log_task_start "install_ubuntu_mono_fontset"
  local P="${TARGET_USER}"
  local H="$(eval echo ~${P})"
  local FD="${H}/.local/share/fonts"
  mkdir -p "${FD}" || true
  local base="https://raw.githubusercontent.com/google/fonts/main/ufl/ubuntumono"
  local files=(UbuntuMono-Regular.ttf UbuntuMono-Italic.ttf UbuntuMono-Bold.ttf UbuntuMono-BoldItalic.ttf)
  for f in "${files[@]}"; do
    local tgt="${FD}/${f}"
    [ -f "${tgt}" ] && continue
    if download_file "${base}/${f}" "/tmp/${f}"; then
      mv -f "/tmp/${f}" "${tgt}" 2>/dev/null || continue
      chown "${P}:${P}" "${tgt}" 2>/dev/null || true
      chmod 0644 "${tgt}" 2>/dev/null || true
    else
      log_warn "no downloader for fonts"
      break
    fi
  done
  if command -v fc-cache >/dev/null 2>&1; then
    sudo -u "${P}" fc-cache -frv "${FD}" >/dev/null 2>&1 || true
  fi
  log_task_done "install_ubuntu_mono_fontset"
}

# -----------------------
# Sublime helpers
# -----------------------
setup_sublime(){
  # Install Sublime Text with Package Control and user preferences.
  log_info "setup_sublime: start"
  refresh_target_context

  mkdir -p /etc/apt/keyrings >/dev/null 2>&1 || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg | tee /etc/apt/keyrings/sublimehq-pub.asc >/dev/null 2>&1 || log_warn "sublime gpg fetch failed"
  fi
  printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' > /etc/apt/sources.list.d/sublime-text.sources 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y sublime-text >/dev/null 2>&1 || log_warn "sublime install failed"

  local DATA_DIR="${USER_HOME}/.config/sublime-text"
  [ -d "${DATA_DIR}" ] || DATA_DIR="${USER_HOME}/.config/sublime-text-3"
  mkdir -p "${DATA_DIR}/Installed Packages" 2>/dev/null || true
  local PC_URL="https://packagecontrol.io/Package%20Control.sublime-package"
  local PC_TARGET="${DATA_DIR}/Installed Packages/Package Control.sublime-package"
  if sudo -u "${TARGET_USER}" test -f "${PC_TARGET}" >/dev/null 2>&1; then
    log_info "Package Control present"
  else
    if command -v curl >/dev/null 2>&1; then
      run_as_target_user "curl -fsSL '${PC_URL}' -o '${PC_TARGET}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
    elif command -v wget >/dev/null 2>&1; then
      run_as_target_user "wget -qO '${PC_TARGET}' '${PC_URL}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
    else
      log_warn "no downloader for packagecontrol"
    fi
    chown "${TARGET_USER}:${TARGET_USER}" "${PC_TARGET}" 2>/dev/null || true
    chmod 0644 "${PC_TARGET}" 2>/dev/null || true
  fi

  local DEST_DIR="${DATA_DIR}/Packages/User"
  local DEST_FILE="${DEST_DIR}/Preferences.sublime-settings"
  local SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/Preferences.sublime-settings"
  mkdir -p "${DEST_DIR}" 2>/dev/null || true
  local TMP="$(mktemp -p /tmp prefs.XXXXXX)" || TMP="/tmp/prefs.$$"
  if ! download_file "${SRC_URL}" "${TMP}"; then
    rm -f "${TMP}"
    log_warn "downloader missing for sublime prefs"
    TMP=""
  fi
  if [ -n "${TMP}" ] && [ -f "${TMP}" ]; then
    if [ -f "${DEST_FILE}" ] && cmp -s "${TMP}" "${DEST_FILE}"; then
      rm -f "${TMP}"
      log_info "Sublime prefs identical; skip"
    else
      mv -f "${TMP}" "${DEST_FILE}" && chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true
      chmod 0644 "${DEST_FILE}" 2>/dev/null || true
      log_info "download_sublime_preferences: installed"
    fi
  fi

  local PKG_DIR="${DATA_DIR}/Installed Packages"
  mkdir -p "${PKG_DIR}" 2>/dev/null || true
  local TMPD="$(mktemp -d 2>/dev/null || echo /tmp/materialize.$$)"
  local ZIPURL="https://github.com/zyphlar/Materialize/archive/refs/heads/master.zip"
  if ! download_file "${ZIPURL}" "${TMPD}/m.zip"; then
    log_warn "materialize download failed"
  fi
  (cd "${TMPD}" 2>/dev/null && unzip -q m.zip) 2>/dev/null || true
  local EX="$(find "${TMPD}" -maxdepth 1 -type d -name "*Materialize*" -print -quit || true)"
  local PACK="${TMPD}/pack"; mkdir -p "${PACK}"
  [ -n "${EX}" ] && mv "${EX}/"* "${PACK}/" 2>/dev/null || true
  (cd "${PACK}" 2>/dev/null && zip -r -q "${TMPD}/Materialize.sublime-package" .) 2>/dev/null || true
  mv -f "${TMPD}/Materialize.sublime-package" "${PKG_DIR}/Materialize.sublime-package" 2>/dev/null || log_warn "move failed"
  chown "${TARGET_USER}:${TARGET_USER}" "${PKG_DIR}/Materialize.sublime-package" 2>/dev/null || true
  rm -rf "${TMPD}" 2>/dev/null || true

  sudo chown $SUDO_USER:$SUDO_USER $DATA_DIR
  sudo chmod 755 $DATA_DIR

  log_info "setup_sublime: done"
}


# -----------------------
# XFCE power/compositing & system lid
# -----------------------

# helper: populate session env vars for the desktop user
_get_desktop_session_info(){
  RUN_AS="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
  PID="$(pgrep -u "$RUN_AS" -n xfce4-panel 2>/dev/null || pgrep -u "$RUN_AS" -n xfce4-session 2>/dev/null || pgrep -u "$RUN_AS" -n dbus-daemon 2>/dev/null || true)"
  DISPLAY_VAL=""; DBUS_ADDR=""; XDG_RUNTIME_DIR=""; XAUTH=""
  if [ -n "$PID" ] && [ -r "/proc/$PID/environ" ]; then
    env_blob="$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null || true)"
    DISPLAY_VAL="$(printf "%s\n" "$env_blob" | awk -F= '/^DISPLAY=/{print substr($0, index($0,$2)); exit}')"
    DBUS_ADDR="$(printf "%s\n" "$env_blob" | awk -F= '/^DBUS_SESSION_BUS_ADDRESS=/{print substr($0, index($0,$2)); exit}')"
    XDG_RUNTIME_DIR="$(printf "%s\n" "$env_blob" | awk -F= '/^XDG_RUNTIME_DIR=/{print substr($0, index($0,$2)); exit}')"
    XAUTH="$(printf "%s\n" "$env_blob" | awk -F= '/^XAUTHORITY=/{print substr($0, index($0,$2)); exit}')"
  fi
  [ -z "$DISPLAY_VAL" ] && DISPLAY_VAL=":0"
  if [ -z "$XAUTH" ]; then
    XAUTH="/home/$RUN_AS/.Xauthority"
    [ ! -f "$XAUTH" ] && XAUTH=""
  fi
}

# helper: run a command as desktop user with session env injected (fixed quoting)
_run_as_desktop_user(){
  # usage: _run_as_desktop_user "command string"
  CMD="$1"
  _get_desktop_session_info

  # build export prefix safely by shell-escaping values
  exports=""
  [ -n "$DISPLAY_VAL" ] && exports+="export DISPLAY=$(printf '%q' "$DISPLAY_VAL"); "
  [ -n "$DBUS_ADDR" ] && exports+="export DBUS_SESSION_BUS_ADDRESS=$(printf '%q' "$DBUS_ADDR"); "
  [ -n "$XDG_RUNTIME_DIR" ] && exports+="export XDG_RUNTIME_DIR=$(printf '%q' "$XDG_RUNTIME_DIR"); "
  [ -n "$XAUTH" ] && exports+="export XAUTHORITY=$(printf '%q' "$XAUTH"); "

  full_cmd="${exports}${CMD}"

  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$RUN_AS" -H bash -lc "$full_cmd"
  else
    bash -lc "$full_cmd"
  fi
}

# spread out xfce panel & show labels (uses _run_as_desktop_user)
spread_xfce_panel(){
  log_task_start "spread_xfce_panel"
  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    log_warn "xfconf-query not available for desktop user; skipping"
    return 0
  fi

  plugins_out="$(_run_as_desktop_user 'xfconf-query -c xfce4-panel -p /plugins -l -v' )" || { log_warn "cannot list panel plugins"; return 0; }
  plugin_numbers="$(printf "%s" "$plugins_out" | grep -E "windowbuttons|tasklist" | awk '{print $1}' | cut -d "-" -f2 || true)"
  if [ -z "$plugin_numbers" ]; then
    log_warn "no windowbuttons/tasklist plugin found"
    return 0
  fi

  for p in $plugin_numbers; do
    grp_prop="/plugins/plugin-$p/grouping"
    lbl_prop="/plugins/plugin-$p/show-labels"
    log_info "plugin-$p: set grouping=0"
    _run_as_desktop_user "xfconf-query -c xfce4-panel -p '$grp_prop' >/dev/null 2>&1 && xfconf-query -c xfce4-panel -p '$grp_prop' -s 0 || xfconf-query -c xfce4-panel -p '$grp_prop' -n -t int -s 0" || log_warn "could not set $grp_prop"
    log_info "plugin-$p: set show-labels=true"
    _run_as_desktop_user "xfconf-query -c xfce4-panel -p '$lbl_prop' >/dev/null 2>&1 && xfconf-query -c xfce4-panel -p '$lbl_prop' -s true || xfconf-query -c xfce4-panel -p '$lbl_prop' -n -t bool -s true" || log_warn "could not set $lbl_prop"
  done
  log_task_done "spread_xfce_panel"
}

# update wallpaper - not working on fresh install - have to open the desktop UI once and set wallpaper - then this works lol
update_wallpaper(){
  log_task_start "update_wallpaper"
  apt-get -y update >/dev/null 2>&1
  apt-get -y install kali-wallpapers-2024 >/dev/null 2>&1
 
  IMG="/usr/share/backgrounds/kali/kali-metal-dark-16x9.png"
  if [ ! -f "$IMG" ]; then
    log_warn "image missing: $IMG"
    return 0
  fi

  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    log_warn "xfconf-query not available for desktop user; skipping wallpaper update"
    return 0
  fi

  keys="$(_run_as_desktop_user 'xfconf-query -c xfce4-desktop -p /backdrop -l -R' | grep "last-image" || true)"
  if [ -z "$keys" ]; then
    log_warn "no wallpaper keys found"
    return 0
  fi

  printf "%s\n" "$keys" | while IFS= read -r key; do
    log_info "setting wallpaper for key: $key"
    _run_as_desktop_user "xfconf-query -c xfce4-desktop -p '$key' -s '$IMG'" || log_warn "xfconf-query failed for $key"
  done

  _run_as_desktop_user 'xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorVirtual1/workspace0/last-image -n -t string -s /usr/share/backgrounds/kali/kali-metal-dark-16x9.png'


  log_task_done "update_wallpaper"
}


disable_xfce_compositing_fast(){
  # Disable XFCE compositing to improve VM performance.
  log_task_start "disable_xfce_compositing_fast"
  # ensure xfconf available in desktop session
  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    log_warn "xfconf-query not available for desktop user; skipping compositing change"
    return 0
  fi

  cur="$(_run_as_desktop_user 'xfconf-query -c xfwm4 -p /general/use_compositing' 2>/dev/null || true)"
  if [ "$cur" = "false" ]; then
    log_info "compositing already disabled"
    return 0
  fi

  log_info "disabling compositing"
  _run_as_desktop_user "xfconf-query --channel=xfwm4 --property=/general/use_compositing >/dev/null 2>&1 && xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --set=false || xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --create --set=false" || \
    log_warn "could not set /general/use_compositing"
  log_task_done "disable_xfce_compositing_fast"
}

install_xfce_power_manager_xml(){
  # Drop in the XFCE power manager config for the target user.
  log_task_start "install_xfce_power_manager_xml"
  refresh_target_context
  local SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/xfce4-power-manager.xml"
  local DEST_DIR="${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
  local DEST_FILE="${DEST_DIR}/xfce4-power-manager.xml"

  mkdir -p "${DEST_DIR}" || { log_warn "mkdir failed: ${DEST_DIR}"; return 1; }
  local TMP="$(mktemp -p /tmp xfcepm.XXXXXX)" || TMP="/tmp/xfcepm.$$"

  if ! download_file "${SRC_URL}" "${TMP}"; then
    rm -f "${TMP}" 2>/dev/null || true
    log_warn "no downloader (curl/wget) available"
    return 1
  fi

  if [ -f "${DEST_FILE}" ] && cmp -s "${TMP}" "${DEST_FILE}"; then
    rm -f "${TMP}"
    log_info "xfce power xml identical; no change"
    return 0
  fi

  mv -f "${TMP}" "${DEST_FILE}" || { log_warn "mv failed"; rm -f "${TMP}" 2>/dev/null || true; return 1; }
  chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true
  chmod 0644 "${DEST_FILE}" 2>/dev/null || true
  log_info "installed xfce power manager xml -> ${DEST_FILE}"

  if _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    log_info "notifying xfce session about new power-manager config"
    _run_as_desktop_user "xfconf-query -c xfce4-power-manager -p / -l >/dev/null 2>&1 || true" || true
  fi

  log_task_done "install_xfce_power_manager_xml"
}




set_lid_switch_ignore(){
  # Disable lid switch actions so the VM never suspends.
  log_info "set_lid_switch_ignore: start"
  FILE="/etc/systemd/logind.conf"; touch "${FILE}" || log_warn "cannot touch ${FILE}"
  sed -i -E 's/^[[:space:]]*#?[[:space:]]*HandleLidSwitch([[:space:]]*=.*)?/HandleLidSwitch=ignore/' "${FILE}" || true
  sed -i -E 's/^[[:space:]]*#?[[:space:]]*HandleLidSwitchExternalPower([[:space:]]*=.*)?/HandleLidSwitchExternalPower=ignore/' "${FILE}" || true
  grep -Eq '^[[:space:]]*HandleLidSwitch=' "${FILE}" || echo 'HandleLidSwitch=ignore' >> "${FILE}"
  grep -Eq '^[[:space:]]*HandleLidSwitchExternalPower=' "${FILE}" || echo 'HandleLidSwitchExternalPower=ignore' >> "${FILE}"
  if command -v systemctl >/dev/null 2>&1; then systemctl restart systemd-logind || log_warn "restart systemd-logind failed"; else log_warn "systemctl missing; reboot required"; fi
  log_info "set_lid_switch_ignore: done"
}



# XFCE auto lock
disable_auto_lock_xfce(){
  # Turn off XFCE auto-lock and display blanking settings.
  log_info "disable_auto_lock_xfce:start"
  set -e
  refresh_target_context

  run_as_target_user "xfconf-query -c xfce4-screensaver -p /lock-enabled -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /lock-enabled -s false || true"
  run_as_target_user "xfconf-query -c xfce4-screensaver -p /idle-activation-enabled -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /idle-activation-enabled -s false || true"
  run_as_target_user "xfconf-query -c xfce4-screensaver -p /saver/enabled -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /saver/enabled -s false || true"
  run_as_target_user "xfconf-query -c xfce4-screensaver -p /saver/lock -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /saver/lock -s false || true"

  run_as_target_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 || true"
  run_as_target_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -n -t int -s 0 || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -s 0 || true"
  run_as_target_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false || true"
  run_as_target_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -n -t bool -s false || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s false || true"

  log_info "disable_auto_lock_xfce:done"
}




# -----------------------
# zsh .zshrc updates (working PROMPT block)
# -----------------------

set_zsh_prompt_symbol_to_at(){
  log_info "set_zsh_prompt_symbol_to_at: start"

  TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  [ -n "$TARGET_USER" ] || { log_warn "Cannot determine target user"; return 1; }
  USER_HOME="${USER_HOME:-$(eval echo ~"${TARGET_USER}")}"
  ZSHRC="${USER_HOME}/.zshrc"

  if [ "$(id -u)" -eq 0 ]; then
    RUN_AS=(sudo -u "${TARGET_USER}" bash -lc)
    SUDO_ROOT="sudo"
  else
    RUN_AS=(bash -lc)
    SUDO_ROOT=""
  fi

  "${RUN_AS[@]}" "touch '${ZSHRC}'" || { log_warn "cannot touch ${ZSHRC}"; return 1; }

  # remove orphaned duplicate second-line + any prior block
  ${SUDO_ROOT} sed -i -E '/^[[:space:]]*└─%B.*%b%F\{reset\} .*/d' "${ZSHRC}"
  ${SUDO_ROOT} sed -i -E '/^# >>> postinstall PROMPT START$/,/^# <<< postinstall PROMPT END$/d' "${ZSHRC}"

  # write block to temp, protect from expansion, then relax perms for user read
  TMP="$(mktemp)" || { log_warn "mktemp failed"; return 1; }
  cat > "${TMP}" <<'ZSH_PROMPT_EOF'
# >>> postinstall PROMPT START
# set by postinstall - prompt symbol + custom PROMPT (replaces previous PROMPT)
prompt_symbol=@
PROMPT=$'%F{%(#.blue.green)}┌──${debian_chroot:+($debian_chroot)─}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n'$prompt_symbol$'%m%b%F{%(#.blue.green)} - %{$fg[yellow]%}[%D{%f/%m/%y} %D{%L:%M:%S})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]\n└─%B%(#.%F{red}#.%F{blue}$)%b%F{reset} '
# <<< postinstall PROMPT END
ZSH_PROMPT_EOF
  chmod 0644 "${TMP}"

  # append as target user, then clean up
  "${RUN_AS[@]}" "cat '${TMP}' >> '${ZSHRC}'" || { rm -f "${TMP}"; log_warn "failed to append prompt block"; return 1; }
  rm -f "${TMP}"

  ${SUDO_ROOT} chown "${TARGET_USER}:${TARGET_USER}" "${ZSHRC}" 2>/dev/null || true
  ${SUDO_ROOT} chmod 0644 "${ZSHRC}" 2>/dev/null || true

  log_info "set_zsh_prompt_symbol_to_at: done"
  return 0
}





# -----------------------
# fzf install
# -----------------------
# Clone and install fzf for the target user.
install_fzf_for_user(){
  log_info "install_fzf_for_user: start"
  FZF_DIR="${USER_HOME}/.fzf"
  if [ -d "${FZF_DIR}/.git" ]; then sudo -u "${TARGET_USER}" git -C "${FZF_DIR}" pull --ff-only --recurse-submodules >/dev/null 2>&1 || log_warn "fzf update failed"; else sudo -u "${TARGET_USER}" rm -rf "${FZF_DIR}" 2>/dev/null || true; sudo -u "${TARGET_USER}" git clone --depth 1 https://github.com/junegunn/fzf.git "${FZF_DIR}" >/dev/null 2>&1 || log_warn "fzf clone failed"; fi
  sudo -u "${TARGET_USER}" bash -lc "${FZF_DIR}/install --all" >/dev/null 2>&1 || log_warn "fzf install returned non-zero"
  log_info "install_fzf_for_user: done"
}

# -----------------------
# tmux conf + plugins
# -----------------------
# Pull tmux.conf and keep tmux plugins in sync.
install_tmux_conf_and_plugins(){
  log_info "install_tmux_conf_and_plugins: start"
  DEST_FILE="${USER_HOME}/.tmux.conf"; SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/.tmux.conf"
  TMP="$(mktemp -p /tmp tmuxconf.XXXXXX)" || TMP="/tmp/tmuxconf.$$"
  if ! download_file "${SRC_URL}" "${TMP}"; then
    rm -f "${TMP}" || true
    log_warn "no downloader"
    return 1
  fi
  mv -f "${TMP}" "${DEST_FILE}"; chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true; chmod 0644 "${DEST_FILE}" || true
  PLUGIN_DIR="${USER_HOME}/.tmux/plugins"; sudo -u "${TARGET_USER}" mkdir -p "${PLUGIN_DIR}"
  repos=( "https://github.com/tmux-plugins/tpm.git::tpm" "https://github.com/tmux-plugins/tmux-yank.git::tmux-yank" "https://github.com/tmux-plugins/tmux-logging.git::tmux-logging" "https://github.com/tmux-plugins/tmux-resurrect.git::tmux-resurrect" )
  for e in "${repos[@]}"; do repo="${e%%::*}"; sub="${e##*::}"; target="${PLUGIN_DIR}/${sub}"
    if [ -d "${target}/.git" ]; then sudo -u "${TARGET_USER}" git -C "${target}" pull --ff-only --recurse-submodules >/dev/null 2>&1 || log_warn "git pull ${sub} failed"
    else sudo -u "${TARGET_USER}" rm -rf "${target}" 2>/dev/null || true; sudo -u "${TARGET_USER}" git clone --depth 1 "${repo}" "${target}" >/dev/null 2>&1 || log_warn "git clone ${repo} failed"; fi
    chown -R "${TARGET_USER}:${TARGET_USER}" "${target}" 2>/dev/null || true
  done
  log_info "install_tmux_conf_and_plugins: done"
}

# -----------------------
# Raw pipx installer (no sudo, exactly as requested)
# -----------------------
# Install NetExec straight from git via pipx.
install_netexec_via_pipx_raw(){
  log_info "install_netexec_via_pipx_raw: running pipx install"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install git+https://github.com/Pennyw0rth/NetExec'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_info "install_netexec_via_pipx_raw: finished (check exit status)"
}


# Install BloodHound CE via pipx.
install_bloodhoundce_via_pipx_raw(){
  log_info "install_bloodhoundce_via_pipx_raw: running pipx install"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install bloodhound-ce'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_info "install_bloodhoundce_via_pipx_raw: finished (check exit status)"
}


# -----------------------
# Setup dirsearch
# -----------------------
# Clone/update dirsearch and wire its virtualenv.
setup_dirsearch() {
  log_info "setup_dirsearch: start"
  T="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  H="$(eval echo ~${T})"
  TARGET_USER="${T}"
  run_as_target_user "set -euo pipefail
    mkdir -p \"${H}/tools/web\"
    cd \"${H}/tools/web\"
    if [ -d dirsearch/.git ]; then
      cd dirsearch
      git pull --ff-only
    else
      git clone https://github.com/maurosoria/dirsearch
      cd dirsearch
    fi
    python3 -m venv env
    . env/bin/activate
    pip install -r requirements.txt
    deactivate
  "
  log_info "setup_dirsearch: done"
}


install_bat_v0_25_via_gdebi() {
  # Install bat 0.25.0 via gdebi and expose a cat alias.
  log_info "install_bat_v0_25_via_gdebi: start"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed"
  apt-get install -y gdebi curl >/dev/null 2>&1 || log_warn "installing gdebi/curl failed"

  URL="https://github.com/sharkdp/bat/releases/download/v0.25.0/bat_0.25.0_amd64.deb"
  TMP_DEB="/tmp/bat_0.25.0_amd64.deb"
  rm -f "${TMP_DEB}" >/dev/null 2>&1 || true

  download_file "${URL}" "${TMP_DEB}" >/dev/null 2>&1 || { log_warn "download failed"; return 1; }

  if [ ! -s "${TMP_DEB}" ]; then
    log_warn "downloaded file is empty: ${TMP_DEB}"
    rm -f "${TMP_DEB}" >/dev/null 2>&1 || true
    return 1
  fi

  if command -v gdebi >/dev/null 2>&1; then
    gdebi -n "${TMP_DEB}" >/dev/null 2>&1 || {
      log_warn "gdebi install failed; falling back to dpkg"
      dpkg -i "${TMP_DEB}" >/dev/null 2>&1 || true
      apt-get -y -f install >/dev/null 2>&1 || log_warn "apt-get -f install failed"
    }
  else
    dpkg -i "${TMP_DEB}" >/dev/null 2>&1 || true
    apt-get -y -f install >/dev/null 2>&1 || log_warn "apt-get -f install failed"
  fi

  rm -f "${TMP_DEB}" >/dev/null 2>&1 || true
  log_info "install_bat_v0_25_via_gdebi: done (check with 'bat --version' or 'batcat --version')"

  # Ensure alias cat is set (replace or append) - fixed quoting
  ZSHRC="${USER_HOME}/.zshrc"
  DESIRED_ALIAS_CAT="alias cat='bat -pp'"
  if sudo grep -q -E '^[[:space:]]*alias[[:space:]]+cat[[:space:]]*=' "${ZSHRC}"; then
    # use | as sed delimiter so single quotes in replacement are safe
    sudo sed -i -E "s|^[[:space:]]*alias[[:space:]]+cat[[:space:]]*=.*|${DESIRED_ALIAS_CAT}|" "${ZSHRC}" || log_warn "failed to replace alias cat"
  else
    # append with proper escaping of single quotes
    sudo bash -lc "printf '\n# set by postinstall\nalias cat='\''bat -pp'\''\n' >> '${ZSHRC}'" || log_warn "failed to append alias cat"
  fi

  return 0
}

gunzip_rockyou(){
  # Extract the bundled rockyou wordlist.
  SRC="/usr/share/wordlists/rockyou.txt.gz"
  if [ ! -f "$SRC" ]; then
    log_warn "$SRC not found"
    return 0
  fi

  # prefer no-op sudo if already root
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi

  log_info "gunzip_rockyou: starting"
  $SUDO gunzip -d "$SRC" >/dev/null 2>&1 || { log_warn "gunzip failed"; return 1; }
  log_info "gunzip_rockyou: done"
  return 0
}



clone_sliver_cheatsheet(){
  # Clone or refresh the sliver cheatsheet helper repo.
  log_info "clone_sliver_cheatsheet: start"
  DEST="$HOME/tools"
  REPO="https://github.com/Anon-Exploiter/sliver-cheatsheet.git"
  NAME="sliver-cheatsheet"
  command -v git >/dev/null 2>&1 || { echo "git missing"; return 1; }
  mkdir -p "$DEST" || { echo "mkdir failed"; return 1; }
  if [ -d "$DEST/$NAME/.git" ]; then
    echo "repo exists, pulling"
    git -C "$DEST/$NAME" pull --rebase --autostash >/dev/null 2>&1 || echo "git pull failed"
  else
    git -C "$DEST" clone "$REPO" >/dev/null 2>&1 || { echo "git clone failed"; return 1; }
  fi
  log_info "clone_sliver_cheatsheet: done"
}


install_openjdk11_for_cobaltstrike(){
  # Bring in OpenJDK 11 for Cobalt Strike usage.
  log_info "install_openjdk11_for_cobaltstrike:start"

  # prefer no-op sudo if already root
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi

  export DEBIAN_FRONTEND=noninteractive

  $SUDO apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed"
  $SUDO apt-get install -y openjdk-11-jdk || log_warn "apt-get install"
  if [ $? -ne 0 ]; then
    log_warn "openjdk-11-jdk install failed"
    return 1
  fi

  log_info "install_openjdk11_for_cobaltstrike:done"
  return 0
}





# Internal




install_frida_pipx(){
  # Install frida-tools via pipx for the mobile toolkit.
  log_task_start "install_frida_pipx"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install frida-tools'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_task_done "install_frida_pipx"
}





setup_mobsf(){
  # Prepare the MobSF docker image and data directory.
  log_task_start "setup_mobsf"
  IMAGE="opensecurity/mobile-security-framework-mobsf:latest"
  USERNAME="${TARGET_USER:-${SUDO_USER:-$(logname || echo $USER)}}"
  USERHOME="$(eval echo ~${USERNAME})"
  DEST="$USERHOME/tools/mobile/mobsf-docker"
  if ! command -v docker >/dev/null 2>&1; then
    log_warn "docker missing; install docker first"; return 1
  fi
  docker pull "$IMAGE"
  sudo -u "${TARGET_USER}" bash -lc "mkdir -p $DEST"
  sudo chown 9901:9901 -Rv "$DEST" || log_warn "sudo chown failed"
  log_info "To start mobsf -> http://localhost:8000"
  log_info "sudo docker run -it --rm -p 8000:8000 -v /home/\$USER/tools/mobile/mobsf-docker:/home/mobsf/.MobSF opensecurity/mobile-security-framework-mobsf:latest"
  log_task_done "setup_mobsf"
}



install_adb_platform_tools(){
  # Download Android platform-tools and wire PATH.
  log_task_start "install_adb_platform_tools"
  set -e
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"; [ -z "$TARGET_USER" ] && TARGET_USER="$(whoami)"
  DEST_PARENT="/home/kali/tools/mobile"
  URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
  if [ ! -x "$DEST_PARENT/platform-tools/adb" ]; then
    sudo apt-get update
    sudo apt-get install -y unzip curl
    if [ "${TARGET_USER}" = "$(whoami)" ]; then
      mkdir -p "$DEST_PARENT"
      rm -rf "$DEST_PARENT/platform-tools"
      curl -L -o "$DEST_PARENT/platform-tools.zip" "$URL"
      unzip "$DEST_PARENT/platform-tools.zip" -d "$DEST_PARENT"
      rm -f "$DEST_PARENT/platform-tools.zip"
    else
      sudo -u "$TARGET_USER" bash -lc "mkdir -p '$DEST_PARENT'; rm -rf '$DEST_PARENT/platform-tools'; curl -L -o '$DEST_PARENT/platform-tools.zip' '$URL'; unzip '$DEST_PARENT/platform-tools.zip' -d '$DEST_PARENT'; rm -f '$DEST_PARENT/platform-tools.zip'"
      sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DEST_PARENT"
    fi
  fi
  USER_HOME="$(eval echo "~${TARGET_USER}")"
  ZSHRC="$USER_HOME/.zshrc"
  PATH_LINE='export PATH="/home/kali/tools/mobile/platform-tools:$PATH"'

  if [ "${TARGET_USER}" = "$(whoami)" ]; then
    touch "$ZSHRC"
    grep -qxF "$PATH_LINE" "$ZSHRC" || printf '%s\n' "$PATH_LINE" >> "$ZSHRC"
  else
    sudo -u "$TARGET_USER" bash -lc "touch '$ZSHRC'; grep -qxF '$PATH_LINE' '$ZSHRC' || printf '%s\n' '$PATH_LINE' >> '$ZSHRC'"
  fi
  log_task_done "install_adb_platform_tools"
}



install_scrcpy(){
  # Download the latest scrcpy release and expose it on PATH.
  log_task_start "install_scrcpy"
  refresh_target_context

  local API_URL="https://api.github.com/repos/Genymobile/scrcpy/releases/latest"
  local DL_URL=""
  local TOOLS_DIR="${USER_HOME}/tools/mobile/scrcpy"

  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    DL_URL="$(curl -fsSL "${API_URL}" | jq -r '.assets[] | select(.name|test("scrcpy-linux-x86_64-v.*\\.tar\\.gz$")) | .browser_download_url' | head -n1)"
  fi
  if [ -z "${DL_URL}" ]; then
    log_warn "could not determine latest scrcpy release URL"
    return 1
  fi

  local TMP="/tmp/$(basename "${DL_URL}")"
  if ! download_file "${DL_URL}" "${TMP}"; then
    log_warn "scrcpy download failed"
    return 1
  fi

  mkdir -p "${TOOLS_DIR}" || { log_warn "mkdir failed: ${TOOLS_DIR}"; rm -f "${TMP}" >/dev/null 2>&1 || true; return 1; }

  local TOP_DIR
  TOP_DIR="$( (tar -tzf "${TMP}" 2>/dev/null || true) | head -n1 | cut -d/ -f1)"
  [ -n "${TOP_DIR}" ] || TOP_DIR="scrcpy"

  rm -rf "${TOOLS_DIR}/${TOP_DIR}" 2>/dev/null || true
  if ! tar -xzf "${TMP}" -C "${TOOLS_DIR}"; then
    log_warn "scrcpy extract failed"
    rm -f "${TMP}" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "${TMP}" >/dev/null 2>&1 || true

  chown -R "${TARGET_USER}:${TARGET_USER}" "${TOOLS_DIR}" 2>/dev/null || true

  local ZSHRC="${USER_HOME}/.zshrc"
  local PATH_LINE="export PATH=\"\$HOME/tools/mobile/scrcpy/${TOP_DIR}:\$PATH\""
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "${TARGET_USER}" bash -lc "touch '${ZSHRC}' && sed -i '/tools\\/mobile\\/scrcpy/d' '${ZSHRC}' && (grep -Fxq '${PATH_LINE}' '${ZSHRC}' || printf '%s\n' '${PATH_LINE}' >> '${ZSHRC}')" || log_warn "zshrc path update failed"
  else
    bash -lc "touch '${ZSHRC}' && sed -i '/tools\\/mobile\\/scrcpy/d' '${ZSHRC}' && (grep -Fxq '${PATH_LINE}' '${ZSHRC}' || printf '%s\n' '${PATH_LINE}' >> '${ZSHRC}')" || log_warn "zshrc path update failed"
  fi

  log_task_done "install_scrcpy"
}


install_apktool(){
  # Pull the latest apktool release and add a zsh alias.
  log_task_start "install_apktool"
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}}"
  USERHOME="$(eval echo ~${TARGET_USER})"
  DEST="$USERHOME/tools/mobile/apktool"
  mkdir -p "$DEST" || { echo "mkdir failed"; return 1; }
  # ensure jq available
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq missing — installing"
    $SUDO apt-get update -y
    $SUDO apt-get install -y jq
  fi
  # fetch latest jar url
  if command -v curl >/dev/null 2>&1; then
    URL="$(curl -s https://api.github.com/repos/iBotPeaches/Apktool/releases/latest | jq -r '.assets[] | select(.name|endswith(".jar")) | .browser_download_url' | head -n1)"
  elif command -v wget >/dev/null 2>&1; then
    URL="$(wget -qO- https://api.github.com/repos/iBotPeaches/Apktool/releases/latest | jq -r '.assets[] | select(.name|endswith(".jar")) | .browser_download_url' | head -n1)"
  else
    echo "curl/wget missing; cannot fetch release info"; return 1
  fi
  [ -n "$URL" ] || { echo "no jar URL found"; return 1; }
  FILE="$(basename "$URL")"
  echo "downloading $FILE"
  wget -O "$DEST/$FILE" "$URL" || { echo "download failed"; return 1; }
  # add alias to .zshrc if missing
  ZSHRC="$USERHOME/.zshrc"
  ALIAS_LINE="alias apktool='java -jar $DEST/$FILE'"
  touch "$ZSHRC"
  if grep -Fxq "$ALIAS_LINE" "$ZSHRC" 2>/dev/null; then
    echo "alias already present in $ZSHRC"
  else
    echo "$ALIAS_LINE" >> "$ZSHRC" && echo "alias added to $ZSHRC"
  fi
  log_task_done "install_apktool"
}


install_rms(){
  # Install rms-runtime-mobile-security globally via npm.
  log_task_start "install_rms"
  # ensure npm exists (try to install via apt if missing)
  if ! command -v npm >/dev/null 2>&1; then
    if sudo apt-get update -y && sudo apt-get install -y nodejs npm; then
      return 0
    else
      echo "apt-get failed or you are not root; please install node/npm manually or run this script as root"
      return 1
    fi
  fi

  echo "Installing rms-runtime-mobile-security"
  sudo npm install -g rms-runtime-mobile-security || { echo "npm install failed"; return 1; }
  log_task_done "install_rms"
}


install_jadx(){
  # Fetch the latest JADX release and add it to PATH.
  log_task_start "install_jadx"
  TARGET_USER="${TARGET_USER:-$(logname 2>/dev/null || echo $USER)}"
  USERHOME="$(eval echo ~${TARGET_USER})"
  DEST="$USERHOME/tools/mobile/jadx"
  mkdir -p "$DEST" || { echo "mkdir failed"; return 1; }

  echo "fetching latest jadx release URL"
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    URL="$(curl -s https://api.github.com/repos/skylot/jadx/releases/latest | \
      python3 -c "import sys,json; j=json.load(sys.stdin); a=j.get('assets',[]); u=[x.get('browser_download_url') for x in a if 'win' not in x.get('name','').lower() and (x.get('browser_download_url','').endswith('.zip') or 'linux' in x.get('name','').lower())]; print(u[0] if u else '')")"
  else
    echo "need curl+python3 to fetch release info"; return 1
  fi

  [ -n "$URL" ] || { echo "no download URL found"; return 1; }
  FILE="$(basename "$URL")"
  echo "downloading $FILE"
  curl -L -o "$DEST/$FILE" "$URL" || { echo "download failed"; return 1; }

  echo "extracting $FILE"
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$DEST/$FILE" -d "$DEST" || { echo "unzip failed"; return 1; }
  else
    echo "no unzip tool (install 'unzip')"; return 1
  fi

  echo "removing archive"
  rm -fv "$DEST/$FILE" || true

  ZSHRC="$USERHOME/.zshrc"
  PATH_LINE='export PATH="$HOME/tools/mobile/jadx/bin:$PATH"'
  if grep -Fxq "$PATH_LINE" "$ZSHRC" 2>/dev/null; then
    echo "PATH already in $ZSHRC"
  else
    echo "$PATH_LINE" >> "$ZSHRC" && echo "added PATH to $ZSHRC"
  fi

  log_task_done "install_jadx"
}


# Palera1n for jailbreaking iOS 
install_palera1n(){
  # Install palera1n jailbreak tooling.
  log_info "install_palera1n:start"
  if command -v palera1n >/dev/null 2>&1; then log_info "install_palera1n:already"; return; fi
  sudo apt-get update -y
  sudo apt-get install -y curl || log_warn "curl install failed"
  sudo /bin/sh -c "$(curl -fsSL https://static.palera.in/scripts/install.sh)" || log_warn "palera1n install failed"
  log_info "install_palera1n:done"
}


# Frida iOS Dump
install_frida_ios_dump(){
  # Clone frida-ios-dump and prep python/npm deps.
  log_info "install_frida_ios_dump:start"
  # determine target user/home
  if [ -z "${TARGET_USER}" ]; then
    if [ -n "${SUDO_USER}" ]; then TARGET_USER="${SUDO_USER}"; else TARGET_USER="$(whoami)"; fi
  fi
  USER_HOME=$(eval echo "~${TARGET_USER}")
  TOOLS_DIR="${USER_HOME}/tools/mobile"
  export DEBIAN_FRONTEND=noninteractive

  sudo apt-get update -y
  sudo apt-get install -y git python3-venv python3-pip nodejs npm build-essential || log_warn "deps install failed"

  # clone or update repo as target user
  if [ "${TARGET_USER}" = "$(whoami)" ]; then
    bash -lc "mkdir -p '${TOOLS_DIR}' && cd '${TOOLS_DIR}' && \
      if [ ! -d frida-ios-dump ]; then git clone https://github.com/IPMegladon/frida-ios-dump; fi && \
      cd frida-ios-dump && git fetch --all && git checkout 4f26c0d" || log_warn "git clone/checkout failed"
  else
    sudo -u "${TARGET_USER}" bash -lc "mkdir -p '${TOOLS_DIR}' && cd '${TOOLS_DIR}' && \
      if [ ! -d frida-ios-dump ]; then git clone https://github.com/IPMegladon/frida-ios-dump; fi && \
      cd frida-ios-dump && git fetch --all && git checkout 4f26c0d" || log_warn "git clone/checkout failed"
  fi

  # setup python venv, pip deps, npm build as target user
  if [ "${TARGET_USER}" = "$(whoami)" ]; then
    bash -lc "cd '${TOOLS_DIR}/frida-ios-dump' && python3 -m venv env && . env/bin/activate && \
      pip install --upgrade pip && pip install -r requirements.txt && mkdir -p dist && \
      npm install frida-objc-bridge --save && npm run build || true; deactivate" || log_warn "venv/npm build failed"
  else
    sudo -u "${TARGET_USER}" bash -lc "cd '${TOOLS_DIR}/frida-ios-dump' && python3 -m venv env && . env/bin/activate && \
      pip install --upgrade pip && pip install -r requirements.txt && mkdir -p dist && \
      npm install frida-objc-bridge --save && npm run build || true; deactivate" || log_warn "venv/npm build failed"
  fi

  echo 'Usage: python3 dump.py -H 192.168.10.118 -u mobile -P mobile com.org.app'

  log_info "install_frida_ios_dump:done - repo at ${TOOLS_DIR}/frida-ios-dump"
}



# Install objection
install_objection_editable(){
  # Install objection in editable mode with its agent build.
  log_info "install_objection_editable:start"
  if [ -z "${TARGET_USER}" ]; then
    if [ -n "${SUDO_USER}" ]; then TARGET_USER="${SUDO_USER}"; else TARGET_USER="$(whoami)"; fi
  fi
  USER_HOME=$(eval echo "~${TARGET_USER}")
  TOOLS_DIR="${USER_HOME}/tools/mobile"
  export DEBIAN_FRONTEND=noninteractive

  sudo apt-get update -y
  sudo apt-get install -y git python3-venv python3-pip nodejs npm build-essential || log_warn "deps install failed"

  if [ "${TARGET_USER}" = "$(whoami)" ]; then
    mkdir -p "${TOOLS_DIR}" && cd "${TOOLS_DIR}" || { log_warn "cd tools failed"; return 1; }
    if [ ! -d objection ]; then git clone https://github.com/sensepost/objection || log_warn "git clone failed"; fi
    cd objection || { log_warn "cd objection failed"; return 1; }
    python3 -m venv env
    . env/bin/activate
    pip3 install --upgrade pip
    pip3 install --editable . || log_warn "pip editable install failed"
    cd agent && npm install || log_warn "npm install agent failed"; cd ..
    deactivate || true
  else
    sudo -u "${TARGET_USER}" bash -lc "mkdir -p '${TOOLS_DIR}' && cd '${TOOLS_DIR}' || exit 1; \
      if [ ! -d objection ]; then git clone https://github.com/sensepost/objection; fi; \
      cd objection || exit 1; python3 -m venv env; . env/bin/activate; pip3 install --upgrade pip; \
      pip3 install --editable . || true; cd agent; npm install || true; cd ..; deactivate || true" || log_warn "objection install (sudo) had errors"
  fi

  VENV_BIN="${TOOLS_DIR}/objection/env/bin/objection"
  if [ -x "${VENV_BIN}" ]; then
    sudo ln -sf "${VENV_BIN}" /usr/local/bin/objection || log_warn "symlink failed"
  fi

  if command -v objection >/dev/null 2>&1; then
    log_info "install_objection_editable:ok"
  else
    log_warn "install_objection_editable:objection not in PATH (may require re-login)"
  fi
  log_info "install_objection_editable:done"
}



# for iOS logs
install_libimobiledevice_utils(){
  # Install iOS device utilities for log capture.
  log_info "install_libimobiledevice_utils:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y libimobiledevice-utils ideviceinstaller || log_warn "libimobiledevice install failed"
  log_info "install_libimobiledevice_utils:done"
}


# Grapefruit iOS
install_grapefruit(){
  # Install Grapefruit (igf) via npm.
  log_info "install_grapefruit:start"
  export DEBIAN_FRONTEND=noninteractive
  command -v npm >/dev/null 2>&1 || { sudo apt-get update -y; sudo apt-get install -y npm nodejs || log_warn "node/npm missing"; }
  sudo npm install -g igf || log_warn "npm igf install failed"
  if command -v igf >/dev/null 2>&1; then
    log_info "install_grapefruit:ok"
  else
    log_warn "install_grapefruit:not in PATH"
  fi
  log_info "install_grapefruit:done"
}




# Wifi Tools

install_kali_tools_wireless(){
  # Install Kali's wireless tools meta package.
  log_info "install_kali_tools_wireless:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y kali-tools-wireless || log_warn "kali-tools-wireless install failed"
  log_info "install_kali_tools_wireless:done"
}


install_eaphammer(){
  # Install eaphammer from apt.
  log_info "install_eaphammer:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y eaphammer || log_warn "eaphammer install failed"
  log_info "install_eaphammer:done"
}


install_dhclient_wifi(){
  # Ensure dhclient is present for wifi tooling.
  log_info "install_dhclient_wifi:start"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || log_warn "apt update failed"
  apt-get install -y isc-dhcp-client || log_warn "isc-dhcp-client install failed"
  if ! command -v dhclient >/dev/null 2>&1; then
    log_warn "dhclient not found after install"
  fi
  log_info "install_dhclient_wifi:done"
}


download_pcapfilter_sh(){
  # Fetch the pcapFilter.sh helper into the wifi tools dir.
  log_info "download_pcapfilter_sh:start"

  # must come from the script's env
  if [ -z "${TARGET_USER}" ] || [ -z "${USER_HOME}" ]; then
    log_warn "TARGET_USER/USER_HOME not set"
    return 1
  fi

  URL="https://gist.githubusercontent.com/r4ulcl/f3470f097d1cd21dbc5a238883e79fb2/raw/78e097e1d4a9eb5f43ab0b2763195c04f02c4998/pcapFilter.sh"
  DEST_DIR="${USER_HOME}/tools/wifi"
  DEST_FILE="${DEST_DIR}/pcapFilter.sh"

  # run actions as the invoking user, not root
  if [ "$(id -u)" -eq 0 ]; then
    RUN_AS=(sudo -u "${TARGET_USER}" bash -lc)
  else
    RUN_AS=(bash -lc)
  fi

  "${RUN_AS[@]}" "mkdir -p '${DEST_DIR}'" || { log_warn "mkdir failed: ${DEST_DIR}"; return 1; }

  if command -v curl >/dev/null 2>&1; then
    "${RUN_AS[@]}" "curl -fsSL '${URL}' -o '${DEST_FILE}'" || { log_warn "curl download failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    "${RUN_AS[@]}" "wget -q -O '${DEST_FILE}' '${URL}'" || { log_warn "wget download failed"; return 1; }
  else
    log_warn "neither curl nor wget available"
    return 1
  fi

  "${RUN_AS[@]}" "chmod +x '${DEST_FILE}'" || log_warn "chmod +x failed on ${DEST_FILE}"

  # ensure ownership when running with sudo
  if [ "$(id -u)" -eq 0 ]; then
    chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true
  fi

  log_info "download_pcapfilter_sh:done -> ${DEST_FILE}"
  return 0
}










main(){
  log_info "main: start"

  # parse args
  INSTALL_M=0; INSTALL_I=0; INSTALL_W=0; INSTALL_A=0; INSTALL_WIFI=0
  while getopts "miwaW" opt; do
    case "$opt" in
      m) INSTALL_M=1;;
      i) INSTALL_I=1;;
      w) INSTALL_W=1;;
      a) INSTALL_A=1;;
      W) INSTALL_WIFI=1;;
    esac
  done
  if [ "$INSTALL_A" -eq 1 ]; then INSTALL_M=1; INSTALL_I=1; INSTALL_W=1; INSTALL_WIFI=1; fi

  echo "Selected options:"
  [ "$INSTALL_M" -eq 1 ] && echo "  - mobile (-m): YES" || echo "  - mobile (-m): NO"
  [ "$INSTALL_I" -eq 1 ] && echo "  - internal (-i): YES" || echo "  - internal (-i): NO"
  [ "$INSTALL_W" -eq 1 ] && echo "  - web (-w): YES" || echo "  - web (-w): NO"
  [ "$INSTALL_A" -eq 1 ] && echo "  - all (-a): YES"
  [ "$INSTALL_WIFI" -eq 1 ] && echo "  - wifi (positional): YES" || echo "  - wifi (positional): NO"

  echo "Executing core setup and utilities ..."

  # Upgrades
  configure_noninteractive_apt
  update_and_upgrade_apt
  install_core_packages
  early_install_vm_tools
  ensure_python_tools

  # Fixes
  fix_sudoers_ownership
  configure_passwordless_sudo
  ensure_ssh_key
  install_ubuntu_mono_fontset
  install_xfce_power_manager_xml
  disable_xfce_compositing_fast
  spread_xfce_panel
  set_lid_switch_ignore
  disable_auto_lock_xfce
  set_zsh_prompt_symbol_to_at
  update_wallpaper

  # Utilities
  setup_sublime
  configure_docker
  install_fzf_for_user
  install_tmux_conf_and_plugins
  install_bat_v0_25_via_gdebi
  gunzip_rockyou

  # tools (grouped - conditional)
  # internals
  if [ "$INSTALL_I" -eq 1 ]; then
    echo "==> Running internal tools..."

    install_netexec_via_pipx_raw
    install_bloodhoundce_via_pipx_raw
    clone_sliver_cheatsheet
    install_openjdk11_for_cobaltstrike

  else
    echo "==> Skipping internal tools"
  fi

  # web
  if [ "$INSTALL_W" -eq 1 ]; then
    echo "==> Running web tools..."
    
    setup_dirsearch

  else
    echo "==> Skipping web tools"
  fi

  # mobile
  if [ "$INSTALL_M" -eq 1 ]; then
    echo "==> Running mobile tools..."
    # General
    install_frida_pipx
    setup_mobsf
    install_rms
    install_objection_editable

    # Android
    install_adb_platform_tools
    install_scrcpy
    install_apktool
    install_jadx

    # iOS
    install_palera1n
    install_frida_ios_dump
    install_libimobiledevice_utils
    install_grapefruit

  else
    echo "==> Skipping mobile tools"
  fi

  # wifi toolset (only if positional 'wifi' was passed)
  if [ "$INSTALL_WIFI" -eq 1 ]; then
    echo "==> Installing wifi tools..."

    install_kali_tools_wireless
    install_eaphammer 
    install_dhclient_wifi
    download_pcapfilter_sh

  else
    echo "==> Skipping wifi tools"
  fi

  # done
  log_info "main: finished - run 'exec zsh' in the user session and restart XFCE if needed"
  log_info "Please change the password of the default user with: sudo passwd $USER"
}


main "$@"
