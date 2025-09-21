#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log_info(){ echo "[INFO] $*"; }
log_warn(){ echo "[WARN] $*"; }

# Re-run under sudo for system tasks
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
USER_HOME="$(eval echo ~${TARGET_USER})"

# -----------------------
# Minified helpers
# -----------------------
secure_sudoers_file(){ f="$1"; [ -n "$f" -a -e "$f" ] || return 1; BACKUP="${f}.bak.$(date +%s)"; cp -a "$f" "$BACKUP" 2>/dev/null || true; chown root:root "$f" 2>/dev/null || true; chmod 0440 "$f" 2>/dev/null || true; visudo -c -f "$f" >/dev/null 2>&1 || { log_warn "visudo failed for $f; restoring"; [ -f "$BACKUP" ] && mv -f "$BACKUP" "$f"; return 1; }; }
fix_sudoers_ownership(){ [ -d /etc/sudoers.d ] || return 0; for f in /etc/sudoers.d/*; do [ -e "$f" ] || continue; uid=$(stat -c %u "$f" 2>/dev/null || echo); [ "$uid" = "0" ] && continue; log_warn "fixing owner for $f (uid=$uid)"; secure_sudoers_file "$f" || log_warn "secure_sudoers_file failed for $f"; done; }
configure_passwordless_sudo(){ T="${TARGET_USER}"; [ -n "$T" ] || return 0; FILE="/etc/sudoers.d/${T}_nopasswd"; printf '%s\n' "${T} ALL=(ALL) NOPASSWD:ALL" > "/tmp/$$.sudoers"; mv -f "/tmp/$$.sudoers" "${FILE}"; chown root:root "${FILE}" 2>/dev/null || true; chmod 0440 "${FILE}" 2>/dev/null || true; log_info "passwordless sudo written for ${T}"; }
attempt_fix_broken_with_force_overwrite(){ apt-get -o Dpkg::Options::="--force-overwrite" --fix-broken install -y >/dev/null 2>&1 || { dpkg --configure -a >/dev/null 2>&1 || true; apt-get -o Dpkg::Options::="--force-overwrite" --fix-broken install -y >/dev/null 2>&1 || return 1; }; }
early_install_vmtools(){ apt-get update -y >/dev/null 2>&1 || true; apt-get install -y 'open-vm-tools*' >/dev/null 2>&1 || true; }

# -----------------------
# Package & system tasks
# -----------------------

setup_noninteractive_apt(){
  log_info "setup_noninteractive_apt:start"
  set -e
  # dpkg: keep existing configs unless maintainer scripts handle it
  sudo mkdir -p /etc/apt/apt.conf.d
  printf '%s\n' 'Dpkg::Options{ "--force-confdef"; "--force-confold"; };' \
  | sudo tee /etc/apt/apt.conf.d/90force-conf >/dev/null

  # needrestart: auto-restart services, suppress kernel nags
  sudo mkdir -p /etc/needrestart/conf.d
  printf '%s\n' '$nrconf{restart} = "a";' '$nrconf{kernelhints} = 0;' \
  | sudo tee /etc/needrestart/conf.d/zzz-auto-restart.conf >/dev/null

  log_info "setup_noninteractive_apt:done"
}


apt_update_upgrade(){
  log_info "apt: update & upgrade"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || log_warn "apt update failed"
  apt-get -y upgrade || { log_warn "apt upgrade failed; attempting recovery"; attempt_fix_broken_with_force_overwrite || log_warn "fix-broken failed"; }
  apt-get -y autoremove || true
  apt-get -y autoclean || true
  log_info "apt: done"
}

install_packages(){
  log_info "install_packages: start"
  PACKAGES=(build-essential git curl wget vim tmux htop jq unzip zip apt-transport-https ca-certificates gnupg python3 python3-pip python3-venv python3-dev python-is-python3 python3-virtualenv nmap net-tools tcpdump aircrack-ng hashcat john hydra sqlmap impacket-scripts nikto metasploit-framework burpsuite docker.io docker-compose openvpn wireshark remmina remmina-common remmina-dev gdebi)
  apt-get update || log_warn "apt-get update failed"
  if apt-get install -y "${PACKAGES[@]}"; then
    log_info "install_packages: packages installed"
  else
    log_warn "install_packages: initial install failed; attempting recovery"
    attempt_fix_broken_with_force_overwrite || log_warn "attempt_fix_broken failed"
    if apt-get install -y "${PACKAGES[@]}"; then
      log_info "install_packages: packages installed on retry"
    else
      log_warn "install_packages: install still failed after retry"
    fi
  fi
  log_info "install_packages: done"
}

configure_docker(){
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || log_warn "docker enable/start failed"
    usermod -aG docker "${SUDO_USER:-${TARGET_USER}}" 2>/dev/null || true
    log_info "configure_docker: done"
  fi
}

ensure_ssh_key_exists(){
  log_info "ensure_ssh_key_exists: start"
  SSH_PRI="${USER_HOME}/.ssh/id_ed25519"
  if [ ! -f "${SSH_PRI}" ]; then
    sudo -u "${TARGET_USER}" mkdir -p "$(dirname "${SSH_PRI}")"
    sudo -u "${TARGET_USER}" ssh-keygen -t ed25519 -a 100 -f "${SSH_PRI}" -N "" -C "${TARGET_USER}@$(hostname -s)" >/dev/null 2>&1 || log_warn "ssh-keygen failed"
    log_info "Generated SSH key for ${TARGET_USER}"
  else
    log_info "SSH key exists"
  fi
}

install_python_tools(){
  log_info "install_python_tools: ensuring pipx"
  apt-get install -y pipx python3-pip >/dev/null 2>&1 || true
  sudo -u "${TARGET_USER}" bash -lc 'python3 -m pip install --user pipx >/dev/null 2>&1 || true; python3 -m pipx ensurepath >/dev/null 2>&1 || true' || true
  log_info "install_python_tools: done"
}

install_ubuntu_mono_and_set_xfce_font(){
  log_info "install_ubuntu_mono_and_set_xfce_font: start"
  P="${TARGET_USER}"; H="$(eval echo ~${P})"; FD="${H}/.local/share/fonts"; mkdir -p "${FD}" || true
  base="https://raw.githubusercontent.com/google/fonts/main/ufl/ubuntumono"
  files=(UbuntuMono-Regular.ttf UbuntuMono-Italic.ttf UbuntuMono-Bold.ttf UbuntuMono-BoldItalic.ttf)
  for f in "${files[@]}"; do
    tgt="${FD}/${f}"
    [ -f "${tgt}" ] && continue
    if command -v curl >/dev/null 2>&1; then curl -fsSL "${base}/${f}" -o "/tmp/${f}" || continue
    elif command -v wget >/dev/null 2>&1; then wget -qO "/tmp/${f}" "${base}/${f}" || continue
    else log_warn "no downloader for fonts"; break
    fi
    mv -f "/tmp/${f}" "${tgt}" 2>/dev/null || continue
    chown "${P}:${P}" "${tgt}" 2>/dev/null || true
    chmod 0644 "${tgt}" 2>/dev/null || true
  done
  if command -v fc-cache >/dev/null 2>&1; then sudo -u "${P}" fc-cache -frv "${FD}" >/dev/null 2>&1 || true; fi
  log_info "install_ubuntu_mono_and_set_xfce_font: done"
}

# -----------------------
# Sublime helpers
# -----------------------
setup_sublime(){
  log_info "setup_sublime: start"
  TARGET_USER="${TARGET_USER:-$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")}"
  USER_HOME="${USER_HOME:-$(eval echo ~${TARGET_USER})}"

  # add repo/key + install
  mkdir -p /etc/apt/keyrings >/dev/null 2>&1 || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg | tee /etc/apt/keyrings/sublimehq-pub.asc >/dev/null 2>&1 || log_warn "sublime gpg fetch failed"
  fi
  printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' > /etc/apt/sources.list.d/sublime-text.sources 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y sublime-text >/dev/null 2>&1 || log_warn "sublime install failed"

  # package control
  DATA_DIR="${USER_HOME}/.config/sublime-text"
  [ -d "${DATA_DIR}" ] || DATA_DIR="${USER_HOME}/.config/sublime-text-3"
  mkdir -p "${DATA_DIR}/Installed Packages" 2>/dev/null || true
  PC_URL="https://packagecontrol.io/Package%20Control.sublime-package"
  PC_TARGET="${DATA_DIR}/Installed Packages/Package Control.sublime-package"
  if sudo -u "${TARGET_USER}" test -f "${PC_TARGET}" >/dev/null 2>&1; then
    log_info "Package Control present"
  else
    if command -v curl >/dev/null 2>&1; then
      sudo -u "${TARGET_USER}" bash -lc "curl -fsSL '${PC_URL}' -o '${PC_TARGET}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
    elif command -v wget >/dev/null 2>&1; then
      sudo -u "${TARGET_USER}" bash -lc "wget -qO '${PC_TARGET}' '${PC_URL}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
    else
      log_warn "no downloader for packagecontrol"
    fi
    chown "${TARGET_USER}:${TARGET_USER}" "${PC_TARGET}" 2>/dev/null || true
    chmod 0644 "${PC_TARGET}" 2>/dev/null || true
  fi

  # preferences
  DEST_DIR="${DATA_DIR}/Packages/User"
  DEST_FILE="${DEST_DIR}/Preferences.sublime-settings"
  SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/Preferences.sublime-settings"
  mkdir -p "${DEST_DIR}" 2>/dev/null || true
  TMP="$(mktemp -p /tmp prefs.XXXXXX)" || TMP="/tmp/prefs.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${SRC_URL}" -o "${TMP}" || { rm -f "${TMP}"; log_warn "curl failed"; TMP=""; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMP}" "${SRC_URL}" || { rm -f "${TMP}"; log_warn "wget failed"; TMP=""; }
  else
    log_warn "no curl/wget"
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

  # materialize package
  PKG_DIR="${DATA_DIR}/Installed Packages"
  mkdir -p "${PKG_DIR}" 2>/dev/null || true
  TMPD="$(mktemp -d 2>/dev/null || echo /tmp/materialize.$$)"
  ZIPURL="https://github.com/zyphlar/Materialize/archive/refs/heads/master.zip"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${ZIPURL}" -o "${TMPD}/m.zip" >/dev/null 2>&1 || log_warn "materialize download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMPD}/m.zip" "${ZIPURL}" >/dev/null 2>&1 || log_warn "materialize download failed"
  else
    log_warn "no downloader for materialize"
  fi
  (cd "${TMPD}" 2>/dev/null && unzip -q m.zip) 2>/dev/null || true
  EX="$(find "${TMPD}" -maxdepth 1 -type d -name "*Materialize*" -print -quit || true)"
  PACK="${TMPD}/pack"; mkdir -p "${PACK}"
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
  echo "spread_xfce_panel: start"
  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    echo "xfconf-query not available for desktop user; skipping"
    return 0
  fi

  plugins_out="$(_run_as_desktop_user 'xfconf-query -c xfce4-panel -p /plugins -l -v' )" || { echo "cannot list panel plugins"; return 0; }
  plugin_numbers="$(printf "%s" "$plugins_out" | grep -E "windowbuttons|tasklist" | awk '{print $1}' | cut -d "-" -f2 || true)"
  if [ -z "$plugin_numbers" ]; then
    echo "no windowbuttons/tasklist plugin found"
    return 0
  fi

  for p in $plugin_numbers; do
    grp_prop="/plugins/plugin-$p/grouping"
    lbl_prop="/plugins/plugin-$p/show-labels"
    echo "plugin-$p: set grouping=0"
    _run_as_desktop_user "xfconf-query -c xfce4-panel -p '$grp_prop' >/dev/null 2>&1 && xfconf-query -c xfce4-panel -p '$grp_prop' -s 0 || xfconf-query -c xfce4-panel -p '$grp_prop' -n -t int -s 0" || echo "warning: could not set $grp_prop"
    echo "plugin-$p: set show-labels=true"
    _run_as_desktop_user "xfconf-query -c xfce4-panel -p '$lbl_prop' >/dev/null 2>&1 && xfconf-query -c xfce4-panel -p '$lbl_prop' -s true || xfconf-query -c xfce4-panel -p '$lbl_prop' -n -t bool -s true" || echo "warning: could not set $lbl_prop"
  done
  echo "spread_xfce_panel: done"
}

# update wallpaper - not working on fresh install - have to open the desktop UI once and set wallpaper - then this works lol
update_wallpaper(){
  echo "update_wallpaper: start"
  apt-get -y update >/dev/null 2>&1
  apt-get -y install kali-wallpapers-2024 >/dev/null 2>&1
 
  IMG="/usr/share/backgrounds/kali/kali-metal-dark-16x9.png"
  if [ ! -f "$IMG" ]; then
    echo "image missing: $IMG"
    return 0
  fi

  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    echo "xfconf-query not available for desktop user; skipping wallpaper update"
    return 0
  fi

  keys="$(_run_as_desktop_user 'xfconf-query -c xfce4-desktop -p /backdrop -l -R' | grep "last-image" || true)"
  if [ -z "$keys" ]; then
    echo "no wallpaper keys found"
    return 0
  fi

  printf "%s\n" "$keys" | while IFS= read -r key; do
    echo "setting wallpaper for key: $key"
    _run_as_desktop_user "xfconf-query -c xfce4-desktop -p '$key' -s '$IMG'" || echo "xfconf-query failed for $key"
  done

  _run_as_desktop_user 'xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorVirtual1/workspace0/last-image -n -t string -s /usr/share/backgrounds/kali/kali-metal-dark-16x9.png'


  echo "update_wallpaper: done"
}


disable_xfce_compositing_fast(){
  echo "disable_xfce_compositing_fast: start"
  # ensure xfconf available in desktop session
  if ! _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    echo "xfconf-query not available for desktop user; skipping compositing change"
    return 0
  fi

  cur="$(_run_as_desktop_user 'xfconf-query -c xfwm4 -p /general/use_compositing' 2>/dev/null || true)"
  if [ "$cur" = "false" ]; then
    echo "compositing already disabled"
    return 0
  fi

  echo "disabling compositing"
  _run_as_desktop_user "xfconf-query --channel=xfwm4 --property=/general/use_compositing >/dev/null 2>&1 && xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --set=false || xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --create --set=false" || \
    echo "warning: could not set /general/use_compositing"
  echo "disable_xfce_compositing_fast: done"
}

install_xfce_power_manager_xml(){
  echo "install_xfce_power_manager_xml: start"
  TARGET_USER="${TARGET_USER:-$(logname 2>/dev/null || echo $USER)}"
  USER_HOME="$(eval echo ~${TARGET_USER})"
  SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/xfce4-power-manager.xml"
  DEST_DIR="${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
  DEST_FILE="${DEST_DIR}/xfce4-power-manager.xml"

  mkdir -p "${DEST_DIR}" || { echo "mkdir failed: ${DEST_DIR}"; return 1; }
  TMP="$(mktemp -p /tmp xfcepm.XXXXXX)" || TMP="/tmp/xfcepm.$$"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${SRC_URL}" -o "${TMP}" || { rm -f "${TMP}"; echo "curl failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMP}" "${SRC_URL}" || { rm -f "${TMP}"; echo "wget failed"; return 1; }
  else
    rm -f "${TMP}" 2>/dev/null || true
    echo "no downloader (curl/wget) available"
    return 1
  fi

  if [ -f "${DEST_FILE}" ] && cmp -s "${TMP}" "${DEST_FILE}"; then
    rm -f "${TMP}"
    echo "xfce power xml identical; no change"
    return 0
  fi

  mv -f "${TMP}" "${DEST_FILE}" || { echo "mv failed"; rm -f "${TMP}" 2>/dev/null || true; return 1; }
  chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true
  chmod 0644 "${DEST_FILE}" 2>/dev/null || true
  echo "installed xfce power manager xml -> ${DEST_FILE}"

  # If xfconf-query is available in the desktop session, try to notify session (optional)
  if _run_as_desktop_user 'command -v xfconf-query >/dev/null 2>&1'; then
    echo "notifying xfce session about new power-manager config"
    _run_as_desktop_user "xfconf-query -c xfce4-power-manager -p / -l >/dev/null 2>&1 || true" || true
  fi

  echo "install_xfce_power_manager_xml: done"
}




set_lid_switch_ignore(){
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
  log_info "disable_auto_lock_xfce:start"
  set -e
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"; [ -z "$TARGET_USER" ] && TARGET_USER="$(whoami)"
  USER_HOME="$(eval echo "~${TARGET_USER}")"
  run_as_user(){ if [ "${TARGET_USER}" = "$(whoami)" ]; then bash -lc "$1"; else sudo -u "$TARGET_USER" bash -lc "$1"; fi }

  # XFCE Screensaver: no lock, no idle activation
  run_as_user "xfconf-query -c xfce4-screensaver -p /lock-enabled -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /lock-enabled -s false || true"
  run_as_user "xfconf-query -c xfce4-screensaver -p /idle-activation-enabled -n -t bool -s false || xfconf-query -c xfce4-screensaver -p /idle-activation-enabled -s false || true"

  # Power manager: no blanking, no DPMS, no lock on suspend/hibernate
  run_as_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 || true"
  run_as_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -n -t int -s 0 || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -s 0 || true"
  run_as_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false || true"
  run_as_user "xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -n -t bool -s false || xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s false || true"

  log_info "disable_auto_lock_xfce:done"
}




# -----------------------
# zsh .zshrc updates (working PROMPT block)
# -----------------------

set_zsh_prompt_symbol_to_at(){
  log_info "set_zsh_prompt_symbol_to_at: start"
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  [ -n "$TARGET_USER" ] || { log_warn "Cannot determine target user"; return 1; }
  USER_HOME="$(eval echo ~${TARGET_USER})"
  ZSHRC="${USER_HOME}/.zshrc"
  BACKUP_DIR="${USER_HOME}/.config/.zshrc_backups"
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  HIST_BACKUP="${BACKUP_DIR}/zsh_hist_values.${TIMESTAMP}.bak"

  # ensure file & backup dir
  [ -f "${ZSHRC}" ] || sudo -u "${TARGET_USER}" touch "${ZSHRC}"
  sudo -u "${TARGET_USER}" mkdir -p "${BACKUP_DIR}" || true

  # capture previous single-line values for backup
  prev_histsize="$(sudo awk -F= '/^[[:space:]]*HISTSIZE[[:space:]]*=/{ val=$0; gsub(/^[[:space:]]*HISTSIZE[[:space:]]*=[[:space:]]*/, "", val); print val }' "${ZSHRC}" | tail -n1 || true)"
  prev_savehist="$(sudo awk -F= '/^[[:space:]]*SAVEHIST[[:space:]]*=/{ val=$0; gsub(/^[[:space:]]*SAVEHIST[[:space:]]*=[[:space:]]*/, "", val); print val }' "${ZSHRC}" | tail -n1 || true)"
  prev_prompt="$(sudo grep -E '^[[:space:]]*PROMPT[[:space:]]*=' "${ZSHRC}" | tail -n1 || true)"
  prev_alias_ll="$(sudo grep -E '^[[:space:]]*alias[[:space:]]+ll[[:space:]]*=' "${ZSHRC}" | tail -n1 || true)"
  prev_alias_cat="$(sudo grep -E '^[[:space:]]*alias[[:space:]]+cat[[:space:]]*=' "${ZSHRC}" | tail -n1 || true)"

  # Set HISTSIZE and SAVEHIST (overwrite or append)
  NEW_HISTSIZE="10000000"; NEW_SAVEHIST="200000000"
  if sudo grep -q -E '^[[:space:]]*HISTSIZE[[:space:]]*=' "${ZSHRC}"; then
    sudo sed -i -E "s/^[[:space:]]*HISTSIZE[[:space:]]*=.*/HISTSIZE=${NEW_HISTSIZE}/" "${ZSHRC}" || log_warn "failed to replace HISTSIZE"
  else
    sudo bash -lc "echo $'\\n# set by postinstall\\nHISTSIZE=${NEW_HISTSIZE}' >> '${ZSHRC}'" || log_warn "failed to append HISTSIZE"
  fi
  if sudo grep -q -E '^[[:space:]]*SAVEHIST[[:space:]]*=' "${ZSHRC}"; then
    sudo sed -i -E "s/^[[:space:]]*SAVEHIST[[:space:]]*=.*/SAVEHIST=${NEW_SAVEHIST}/" "${ZSHRC}" || log_warn "failed to replace SAVEHIST"
  else
    sudo bash -lc "echo $'\\n# set by postinstall\\nSAVEHIST=${NEW_SAVEHIST}' >> '${ZSHRC}'" || log_warn "failed to append SAVEHIST"
  fi

  # Remove any existing prompt_symbol and PROMPT lines to avoid duplicates
  sudo sed -i -E '/^[[:space:]]*prompt_symbol[[:space:]]*=.*/d' "${ZSHRC}" || true
  sudo sed -i -E '/^[[:space:]]*PROMPT[[:space:]]*=.*/d' "${ZSHRC}" || true

  # Append prompt_symbol together with PROMPT (line by line) as a literal block
  sudo bash -lc "cat >> '${ZSHRC}' <<'ZSH_PROMPT_EOF'

# set by postinstall - prompt symbol + custom PROMPT (replaces previous PROMPT)
prompt_symbol=@
PROMPT=\$'%F{%(#.blue.green)}┌──\${debian_chroot:+(\$debian_chroot)─}\${VIRTUAL_ENV:+(\$(basename \$VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n'\$prompt_symbol\$'%m%b%F{%(#.blue.green)} - %{\$fg[yellow]%}[%D{%f/%m/%y} %D{%L:%M:%S})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]
└─%B%(#.%F{red}#.%F{blue}\$)%b%F{reset} '
ZSH_PROMPT_EOF
" || { log_warn "failed to append prompt block"; return 1; }

  # Ensure alias ll is set (replace or append)
  DESIRED_ALIAS_LL="alias ll='ls -lah'"
  if sudo grep -q -E '^[[:space:]]*alias[[:space:]]+ll[[:space:]]*=' "${ZSHRC}"; then
    sudo sed -i -E "s/^[[:space:]]*alias[[:space:]]+ll[[:space:]]*=.*/${DESIRED_ALIAS_LL}/" "${ZSHRC}" || log_warn "failed to replace alias ll"
  else
    sudo bash -lc "echo $'\\n# set by postinstall\\n${DESIRED_ALIAS_LL}' >> '${ZSHRC}'" || log_warn "failed to append alias ll"
  fi

  # Fix ownership/permissions
  sudo chown "${TARGET_USER}:${TARGET_USER}" "${ZSHRC}" >/dev/null 2>&1 || log_warn "chown failed on ${ZSHRC}"
  sudo chmod 0644 "${ZSHRC}" >/dev/null 2>&1 || log_warn "chmod failed on ${ZSHRC}"

  log_info "set_zsh_prompt_symbol_to_at: done"
  return 0
}



# -----------------------
# fzf install
# -----------------------
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
install_tmux_conf_and_plugins(){
  log_info "install_tmux_conf_and_plugins: start"
  DEST_FILE="${USER_HOME}/.tmux.conf"; SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/.tmux.conf"
  TMP="$(mktemp -p /tmp tmuxconf.XXXXXX)" || TMP="/tmp/tmuxconf.$$"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "${SRC_URL}" -o "${TMP}" || { rm -f "${TMP}"; log_warn "curl failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then wget -qO "${TMP}" "${SRC_URL}" || { rm -f "${TMP}"; log_warn "wget failed"; return 1; }
  else rm -f "${TMP}" || true; log_warn "no downloader"; return 1; fi
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
install_netexec_via_pipx_raw(){
  log_info "install_netexec_via_pipx_raw: running pipx install"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install git+https://github.com/Pennyw0rth/NetExec'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_info "install_netexec_via_pipx_raw: finished (check exit status)"
}



install_bloodhoundce_via_pipx_raw(){
  log_info "install_bloodhoundce_via_pipx_raw: running pipx install"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install bloodhound-ce'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_info "install_bloodhoundce_via_pipx_raw: finished (check exit status)"
}


# -----------------------
# Setup dirsearch
# -----------------------
setup_dirsearch() {
  log_info "setup_dirsearch: start"
  T="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  H="$(eval echo ~${T})"
  sudo -u "${TARGET_USER}" bash -lc "set -euo pipefail
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
  log_info "install_bat_v0_25_via_gdebi: start"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed"
  apt-get install -y gdebi curl >/dev/null 2>&1 || log_warn "installing gdebi/curl failed"

  URL="https://github.com/sharkdp/bat/releases/download/v0.25.0/bat_0.25.0_amd64.deb"
  TMP_DEB="/tmp/bat_0.25.0_amd64.deb"
  rm -f "${TMP_DEB}" >/dev/null 2>&1 || true

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${URL}" -o "${TMP_DEB}" || { log_warn "curl download failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMP_DEB}" "${URL}" || { log_warn "wget download failed"; return 1; }
  else
    log_warn "no downloader (curl/wget)"
    return 1
  fi

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


clone_sliver_cheatsheet(){
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


install_frida_pipx(){
  log_info "install_frida_pipx: installing frida-tools via pipx"
  sudo -u "${TARGET_USER}" bash -lc 'pipx install frida-tools'
  sudo -u "${TARGET_USER}" bash -lc 'pipx ensurepath'
  log_info "install_frida_pipx: done"
}





setup_mobsf(){
  echo "setup_mobsf: start"
  IMAGE="opensecurity/mobile-security-framework-mobsf:latest"
  USERNAME="${TARGET_USER:-${SUDO_USER:-$(logname || echo $USER)}}"
  USERHOME="$(eval echo ~${USERNAME})"
  DEST="$USERHOME/tools/mobile/mobsf-docker"
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker missing; install docker first"; return 1
  fi
  docker pull "$IMAGE" >/dev/null 2>&1
  sudo -u "${TARGET_USER}" bash -lc "mkdir -p $DEST"
  sudo chown 9901:9901 -Rv "$DEST" || echo "sudo chown failed"
  echo "To start mobsf -> http://localhost:8000"
  echo 'sudo docker run -it --rm -p 8000:8000 -v /home/$USER/tools/mobile/mobsf-docker:/home/mobsf/.MobSF opensecurity/mobile-security-framework-mobsf:latest'
  echo "setup_mobsf: done"
}



install_adb_platform_tools(){
  log_info "install_adb_platform_tools:start"
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
    grep -qxF "$PATH_LINE" "$ZSHRC" || echo "$PATH_LINE" >> "$ZSHRC"
  else
    sudo -u "$TARGET_USER" bash -lc "touch '$ZSHRC'; grep -qxF \"$PATH_LINE\" '$ZSHRC' || echo \"$PATH_LINE\" >> '$ZSHRC'"
  fi
  log_info "install_adb_platform_tools:done"
}



install_apktool(){
  echo "install_apktool: start"
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
  echo "install_apktool: done"
}


install_rms(){
  echo "install_rms: start"
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
  echo "install_rms: done - run by typing 'rms'"
}


install_jadx(){
  echo "install_jadx: start"
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

  echo "install_jadx: done - binaries (if any) in $DEST/bin"
}


# Palera1n for jailbreaking iOS 
install_palera1n(){
  log_info "install_palera1n:start"
  if command -v palera1n >/dev/null 2>&1; then log_info "install_palera1n:already"; return; fi
  sudo apt-get update -y
  sudo apt-get install -y curl || log_warn "curl install failed"
  sudo /bin/sh -c "$(curl -fsSL https://static.palera.in/scripts/install.sh)" || log_warn "palera1n install failed"
  log_info "install_palera1n:done"
}


# Frida iOS Dump
install_frida_ios_dump(){
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
  log_info "install_libimobiledevice_utils:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y libimobiledevice-utils ideviceinstaller || log_warn "libimobiledevice install failed"
  log_info "install_libimobiledevice_utils:done"
}


# Grapefruit iOS
install_grapefruit(){
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
  log_info "install_kali_tools_wireless:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y kali-tools-wireless || log_warn "kali-tools-wireless install failed"
  log_info "install_kali_tools_wireless:done"
}




install_eaphammer(){
  log_info "install_eaphammer:start"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y eaphammer || log_warn "eaphammer install failed"
  log_info "install_eaphammer:done"
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
  setup_noninteractive_apt
  apt_update_upgrade
  install_packages
  early_install_vmtools
  install_python_tools

  # Fixes
  fix_sudoers_ownership
  configure_passwordless_sudo
  ensure_ssh_key_exists
  install_ubuntu_mono_and_set_xfce_font
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

  # tools (grouped - conditional)
  # internals
  if [ "$INSTALL_I" -eq 1 ]; then
    echo "==> Running internal tools..."
    install_netexec_via_pipx_raw
    install_bloodhoundce_via_pipx_raw
    clone_sliver_cheatsheet
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

  else
    echo "==> Skipping wifi tools"
  fi

  # done
  log_info "main: finished - run 'exec zsh' in the user session and restart XFCE if needed"
}


main "$@"
