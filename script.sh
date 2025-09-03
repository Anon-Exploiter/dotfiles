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
apt_update_upgrade(){
  log_info "apt: update & upgrade"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || log_warn "apt update failed"
  apt-get -y upgrade >/dev/null 2>&1 || { log_warn "apt upgrade failed; attempting recovery"; attempt_fix_broken_with_force_overwrite >/dev/null 2>&1 || log_warn "fix-broken failed"; }
  apt-get -y autoremove >/dev/null 2>&1 || true
  apt-get -y autoclean >/dev/null 2>&1 || true
  log_info "apt: done"
}

install_packages(){
  log_info "install_packages: start"
  PACKAGES=(build-essential git curl wget vim tmux htop jq unzip zip apt-transport-https ca-certificates gnupg python3 python3-pip python3-venv python3-dev python-is-python3 python3-virtualenv nmap net-tools tcpdump aircrack-ng hashcat john hydra sqlmap nikto metasploit-framework burpsuite docker.io docker-compose openvpn wireshark remmina remmina-common remmina-dev gdebi kali-wallpapers-2024)
  apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed"
  if apt-get install -y "${PACKAGES[@]}" >/dev/null 2>&1; then
    log_info "install_packages: packages installed"
  else
    log_warn "install_packages: initial install failed; attempting recovery"
    attempt_fix_broken_with_force_overwrite >/dev/null 2>&1 || log_warn "attempt_fix_broken failed"
    if apt-get install -y "${PACKAGES[@]}" >/dev/null 2>&1; then
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
install_sublime_text(){
  log_info "install_sublime_text: best-effort add repo"
  mkdir -p /etc/apt/keyrings >/dev/null 2>&1 || true
  if command -v curl >/dev/null 2>&1; then curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg | tee /etc/apt/keyrings/sublimehq-pub.asc >/dev/null 2>&1; fi
  printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' > /etc/apt/sources.list.d/sublime-text.sources 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y sublime-text >/dev/null 2>&1 || true
  log_info "install_sublime_text: done"
}

install_package_control(){
  log_info "install_package_control: start"
  PUSER="${TARGET_USER}"; PHOME="$(eval echo ~${PUSER})"
  DATA_DIR="${PHOME}/.config/sublime-text"; [ -d "${DATA_DIR}" ] || DATA_DIR="${PHOME}/.config/sublime-text-3"
  mkdir -p "${DATA_DIR}/Installed Packages" 2>/dev/null || true
  PC_URL="https://packagecontrol.io/Package%20Control.sublime-package"
  PC_TARGET="${DATA_DIR}/Installed Packages/Package Control.sublime-package"
  if sudo -u "${PUSER}" test -f "${PC_TARGET}"; then log_info "Package Control present"; return 0; fi
  if command -v curl >/dev/null 2>&1; then sudo -u "${PUSER}" bash -lc "curl -fsSL '${PC_URL}' -o '${PC_TARGET}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
  elif command -v wget >/dev/null 2>&1; then sudo -u "${PUSER}" bash -lc "wget -qO '${PC_TARGET}' '${PC_URL}'" >/dev/null 2>&1 || log_warn "packagecontrol download failed"
  else log_warn "no downloader for packagecontrol"; fi
  chown "${PUSER}:${PUSER}" "${PC_TARGET}" 2>/dev/null || true; chmod 0644 "${PC_TARGET}" 2>/dev/null || true
  log_info "install_package_control: done"
}

download_sublime_preferences(){
  log_info "download_sublime_preferences: start"
  DEST_DIR="${USER_HOME}/.config/sublime-text/Packages/User"
  DEST_FILE="${DEST_DIR}/Preferences.sublime-settings"
  SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/Preferences.sublime-settings"
  mkdir -p "${DEST_DIR}"
  TMP="$(mktemp -p /tmp prefs.XXXXXX)" || TMP="/tmp/prefs.$$"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "${SRC_URL}" -o "${TMP}" || { rm -f "${TMP}"; log_warn "curl failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then wget -qO "${TMP}" "${SRC_URL}" || { rm -f "${TMP}"; log_warn "wget failed"; return 1; }
  else rm -f "${TMP}" || true; log_warn "no curl/wget"; return 1; fi
  if [ -f "${DEST_FILE}" ] && cmp -s "${TMP}" "${DEST_FILE}"; then rm -f "${TMP}"; log_info "Sublime prefs identical; skip"; return 0; fi
  mv -f "${TMP}" "${DEST_FILE}"; chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true; chmod 0644 "${DEST_FILE}" 2>/dev/null || true
  log_info "download_sublime_preferences: installed"
}

install_materialize_sublime_package(){
  log_info "install_materialize_sublime_package: start"
  PUSER="${TARGET_USER}"; PHOME="$(eval echo ~${PUSER})"
  PKG_DIR="${PHOME}/.config/sublime-text/Installed Packages"; mkdir -p "${PKG_DIR}"
  TMPD="$(mktemp -d 2>/dev/null || echo /tmp/materialize.$$)"; ZIPURL="https://github.com/zyphlar/Materialize/archive/refs/heads/master.zip"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "${ZIPURL}" -o "${TMPD}/m.zip" >/dev/null 2>&1 || log_warn "materialize download failed"
  elif command -v wget >/dev/null 2>&1; then wget -qO "${TMPD}/m.zip" "${ZIPURL}" >/dev/null 2>&1 || log_warn "materialize download failed"
  else log_warn "no downloader"; rm -rf "${TMPD}" 2>/dev/null || true; return 1; fi
  (cd "${TMPD}" && unzip -q m.zip) 2>/dev/null || true
  EX="$(find "${TMPD}" -maxdepth 1 -type d -name "*Materialize*" -print -quit || true)"; PACK="${TMPD}/pack"; mkdir -p "${PACK}"
  [ -n "${EX}" ] && mv "${EX}/"* "${PACK}/" 2>/dev/null || true
  (cd "${PACK}" && zip -r -q "${TMPD}/Materialize.sublime-package" .) 2>/dev/null || true
  mv -f "${TMPD}/Materialize.sublime-package" "${PKG_DIR}/Materialize.sublime-package" 2>/dev/null || log_warn "move failed"
  chown "${PUSER}:${PUSER}" "${PKG_DIR}/Materialize.sublime-package" 2>/dev/null || true
  rm -rf "${TMPD}" 2>/dev/null || true
  log_info "install_materialize_sublime_package: done"
}

# -----------------------
# XFCE power/compositing & system lid
# -----------------------
disable_xfce_compositing_fast(){
  log_info "disable_xfce_compositing_fast: start"
  if ! command -v xfconf-query >/dev/null 2>&1; then log_warn "xfconf-query missing"; return 0; fi
  sudo -u "${TARGET_USER}" bash -lc '
    if xfconf-query -c xfwm4 -p /general/use_compositing >/dev/null 2>&1; then cur="$(xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null || echo)"; else cur=""; fi
    if [ "$cur" = "false" ]; then echo "[INFO] compositing already disabled"; exit 0; fi
    xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --set=false --create || exit 1
  '
  log_info "disable_xfce_compositing_fast: done"
}

install_xfce_power_manager_xml(){
  log_info "install_xfce_power_manager_xml: start"
  SRC_URL="https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/xfce4-power-manager.xml"
  DEST_DIR="${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"; DEST_FILE="${DEST_DIR}/xfce4-power-manager.xml"
  mkdir -p "${DEST_DIR}"
  TMP="$(mktemp -p /tmp xfcepm.XXXXXX)" || TMP="/tmp/xfcepm.$$"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "${SRC_URL}" -o "${TMP}" || { rm -f "${TMP}"; log_warn "curl failed"; return 1; }
  elif command -v wget >/dev/null 2>&1; then wget -qO "${TMP}" "${SRC_URL}" || { rm -f "${TMP}"; log_warn "wget failed"; return 1; }
  else rm -f "${TMP}" || true; log_warn "no downloader"; return 1; fi
  if [ -f "${DEST_FILE}" ] && cmp -s "${TMP}" "${DEST_FILE}"; then rm -f "${TMP}"; log_info "xfce power xml identical"; return 0; fi
  mv -f "${TMP}" "${DEST_FILE}"; chown "${TARGET_USER}:${TARGET_USER}" "${DEST_FILE}" 2>/dev/null || true; chmod 0644 "${DEST_FILE}" 2>/dev/null || true
  log_info "install_xfce_power_manager_xml: installed"
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

  if [ -n "${prev_histsize}" ] || [ -n "${prev_savehist}" ] || [ -n "${prev_prompt}" ] || [ -n "${prev_alias_ll}" ] || [ -n "${prev_alias_cat}" ]; then
    {
      echo "# zsh config backup - ${TIMESTAMP}"
      [ -n "${prev_histsize}" ] && echo "HISTSIZE=${prev_histsize}"
      [ -n "${prev_savehist}" ] && echo "SAVEHIST=${prev_savehist}"
      [ -n "${prev_prompt}" ] && echo "PROMPT=${prev_prompt}"
      [ -n "${prev_alias_ll}" ] && echo "ALIAS_LL=${prev_alias_ll}"
      [ -n "${prev_alias_cat}" ] && echo "ALIAS_CAT=${prev_alias_cat}"
    } | sudo tee "${HIST_BACKUP}" >/dev/null || log_warn "failed to write backup ${HIST_BACKUP}"
    sudo chown "${TARGET_USER}:${TARGET_USER}" "${HIST_BACKUP}" >/dev/null 2>&1 || true
    sudo chmod 0600 "${HIST_BACKUP}" >/dev/null 2>&1 || true
    log_info "zsh values backed up to ${HIST_BACKUP}"
  else
    log_info "no existing HISTSIZE/SAVEHIST/PROMPT/alias ll/cat found to back up"
  fi

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

  # Ensure alias cat is set (replace or append) - fixed quoting
  DESIRED_ALIAS_CAT="alias cat='bat -pp'"
  if sudo grep -q -E '^[[:space:]]*alias[[:space:]]+cat[[:space:]]*=' "${ZSHRC}"; then
    # use | as sed delimiter so single quotes in replacement are safe
    sudo sed -i -E "s|^[[:space:]]*alias[[:space:]]+cat[[:space:]]*=.*|${DESIRED_ALIAS_CAT}|" "${ZSHRC}" || log_warn "failed to replace alias cat"
  else
    # append with proper escaping of single quotes
    sudo bash -lc "printf '\n# set by postinstall\nalias cat='\''bat -pp'\''\n' >> '${ZSHRC}'" || log_warn "failed to append alias cat"
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
  pipx install git+https://github.com/Pennyw0rth/NetExec
  pipx ensurepath
  log_info "install_netexec_via_pipx_raw: finished (check exit status)"
}


# -----------------------
# Setup dirsearch
# -----------------------
setup_dirsearch() {
  log_info "setup_dirsearch: start"
  T="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
  H="$(eval echo ~${T})"
  sudo -u "${T}" bash -lc "set -euo pipefail
    mkdir -p \"${H}/tools\"
    cd \"${H}/tools\"
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
  return 0
}



# -----------------------
# Main - call tasks in order
# -----------------------
main(){
  log_info "main: start"
  fix_sudoers_ownership
  configure_passwordless_sudo
  early_install_vmtools
  apt_update_upgrade
  install_packages
  install_sublime_text
  install_package_control
  download_sublime_preferences
  install_materialize_sublime_package
  install_python_tools
  ensure_ssh_key_exists
  configure_docker
  install_ubuntu_mono_and_set_xfce_font
  install_xfce_power_manager_xml
  disable_xfce_compositing_fast
  set_lid_switch_ignore
  set_zsh_prompt_symbol_to_at
  install_fzf_for_user
  install_tmux_conf_and_plugins
  install_netexec_via_pipx_raw
  setup_dirsearch
  install_bat_v0_25_via_gdebi
  log_info "main: finished - run 'exec zsh' in the user session and restart XFCE if needed"
}

main "$@"
