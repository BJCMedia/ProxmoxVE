#!/usr/bin/env bash
# Proxmox VE LXC Updater (hardened)
# Features: Dry-run mode, robust whiptail handling, safe parsing, per-CT error isolation,
# timeouts on shutdown, logging to /var/log/pve-lxc-updater.log

# Copyright (c) 2021-2025 tteck 
# Author: tteck (tteckster) 
# License: MIT 
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE


set -Eeuo pipefail
shopt -s lastpipe

LANG=C

# ---------- Config ----------
LOGFILE="/var/log/pve-lxc-updater.log"
SHUTDOWN_TIMEOUT=60
SLEEP_AFTER_START=5
# ----------------------------

# ---------- Colors ----------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
# ----------------------------

header_info() {
  clear
  cat <<"EOF"
   __  __          __      __          __   _  ________
  / / / /___  ____/ /___ _/ /____     / /  | |/ / ____/
 / / / / __ \/ __  / __ `/ __/ _ \   / /   |   / /
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / /___/   / /___
\____/ .___/\__,_/\__,_/\__/\___/  /_____/_/|_\____/
    /_/
EOF
}

usage() {
  cat <<USAGE
Usage: ${0##*/} [--dry-run]

Options:
  --dry-run   Show what would happen but do not make changes.

Notes:
  - Logs are written to $LOGFILE
  - Requires root and Proxmox 'pct' & 'whiptail' available.
USAGE
}

# ---------- Args ----------
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ "${1:-}" =~ ^- ]]; then
  usage
  exit 2
fi
# ----------------------------

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi
# -------------------------------

# ---------- Logging setup ----------
# Ensure logfile exists with safe perms before tee redirection to avoid whiptail conflicts
init_logging() {
  touch "$LOGFILE" || { echo "Cannot write to $LOGFILE"; exit 1; }
  chmod 600 "$LOGFILE" || true
  {
    printf "\n[%(%F %T)T] ====== Start run (dry_run=%s) ======\n" -1 "$DRY_RUN"
  } >>"$LOGFILE"
  # After whiptail prompts, we switch stdout/stderr to tee into the logfile
  exec > >(tee -a "$LOGFILE") 2>&1
}
# ----------------------------------

log_err() { printf "%s[Error]%s %s\n" "$RD" "$CL" "$*" >&2; }
log_inf() { printf "%s[Info]%s %s\n"  "$BL" "$CL" "$*";   }
log_ok()  { printf "%s[OK]%s %s\n"    "$GN" "$CL" "$*";   }

# Safer command runner that respects dry-run for mutating actions
run_cmd() {
  # usage: run_cmd <description> -- <actual command...>
  local desc
  desc="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift || true
  if $DRY_RUN; then
    log_inf "[DRY-RUN] $desc"
    return 0
  else
    log_inf "$desc"
    "$@"
  fi
}

# Wrapper for pct exec respecting dry-run (read-only commands can pass through)
pct_exec_mutating() {
  # usage: pct_exec_mutating <ctid> -- <shell-command>
  local ctid cmd
  ctid="$1"; shift
  [[ "${1:-}" == "--" ]] && shift || true
  cmd="$*"
  if $DRY_RUN; then
    log_inf "[DRY-RUN] pct exec $ctid -- $cmd"
    return 0
  else
    pct exec "$ctid" -- sh -c "$cmd"
  fi
}

header_info
echo "Loading..."

# Respect the confirmation prompt
if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Proxmox VE LXC Updater" \
  --yesno "This will update LXC containers. Proceed?" 10 58; then
  echo "Cancelled."
  exit 0
fi

NODE=$(hostname)
declare -a EXCLUDE_MENU=()
MSG_MAX_LENGTH=0

# Build checklist safely: take only columns we need (ID and NAME)
# Fallback name is "ct<ID>" if missing.
while IFS= read -r line; do
  ctid=$(awk '{print $1}' <<<"$line")
  name=$(awk '{print $3}' <<<"$line")
  [[ "$ctid" =~ ^[0-9]+$ ]] || continue
  item="${name:-ct$ctid}"
  OFFSET=2
  length=$(( ${#item} + OFFSET ))
  (( length > MSG_MAX_LENGTH )) && MSG_MAX_LENGTH=$length
  EXCLUDE_MENU+=("$ctid" "$item" "OFF")
done < <(pct list | awk 'NR>1 {print $1, $2, $3}')

excluded_raw=$(
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Containers on $NODE" \
  --checklist "\nSelect containers to skip from updates:\n" \
  16 $((MSG_MAX_LENGTH + 23)) 8 \
  "${EXCLUDE_MENU[@]}" 3>&1 1>&2 2>&3 | tr -d '"'
)

# Convert selection to a set
declare -A EXCLUDED
for id in $excluded_raw; do
  EXCLUDED["$id"]=1
done

# Initialize logging AFTER whiptail interactions (so whiptail can use stdout)
init_logging
header_info

$DRY_RUN && log_inf "Dry-run mode is ON. No changes will be made."

containers_needing_reboot=()
failed_containers=()

update_container() {
  local ctid="$1"
  local os name

  # Determine OS (ostype) and hostname
  os=$(pct config "$ctid" | awk '/^ostype/ {print $2}')
  name=$(pct exec "$ctid" -- hostname 2>/dev/null || echo "ct$ctid")

  # Root filesystem usage (more reliable than /boot in containers)
  local disk_info=""
  disk_info=$(pct exec "$ctid" -- sh -c 'df -P / 2>/dev/null | awk "NR==2{gsub(\"%\",\"\",$5); printf \"%s %.1fG %.1fG %.1fG\", $5, $3/1024/1024, $2/1024/1024, $4/1024/1024 }"') || true
  if [[ -n "$disk_info" ]]; then
    read -r pct_used used_gb total_gb free_gb <<<"$disk_info"
    log_inf "Updating $ctid : $name - Root Disk: ${pct_used}%% full [${used_gb}/${total_gb} used, ${free_gb} free]"
  else
    log_inf "Updating $ctid : $name - [No disk info]"
  fi

  # Package manager updates per ostype
  case "$os" in
    alpine)
      pct_exec_mutating "$ctid" -- 'apk -U upgrade'
      ;;
    archlinux)
      pct_exec_mutating "$ctid" -- 'pacman -Syyu --noconfirm'
      ;;
    fedora|rocky|centos|alma)
      pct_exec_mutating "$ctid" -- 'dnf -y update && dnf -y upgrade'
      ;;
    ubuntu|debian|devuan)
      pct_exec_mutating "$ctid" -- 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get -yq dist-upgrade; apt-get -yq autoremove; apt-get -yq autoclean'
      ;;
    opensuse)
      pct_exec_mutating "$ctid" -- 'zypper -n ref && zypper -n dup'
      ;;
    *)
      log_err "Unknown ostype for CT $ctid: '$os'. Skipping."
      return 1
      ;;
  esac

  # Reboot requirement (Debian/Ubuntu-based)
  if pct exec "$ctid" -- test -e /var/run/reboot-required; then
    local h
    h=$(pct exec "$ctid" -- hostname 2>/dev/null || echo "$ctid")
    containers_needing_reboot+=("$ctid ($h)")
  fi
}

# Iterate CTIDs and process
while IFS= read -r ctid; do
  [[ "$ctid" =~ ^[0-9]+$ ]] || continue

  if [[ -n "${EXCLUDED[$ctid]:-}" ]]; then
    log_inf "Skipping $ctid (excluded)"
    continue
  fi

  status=$(pct status "$ctid" 2>/dev/null || true)
  template=false
  if pct config "$ctid" | grep -q '^template:'; then
    template=true
  fi

  if [[ "$template" == "false" && "$status" == "status: stopped" ]]; then
    run_cmd "Starting CT $ctid" -- pct start "$ctid"
    log_inf "Waiting ${SLEEP_AFTER_START}s for $ctid to start"
    sleep "$SLEEP_AFTER_START"
    if ! update_container "$ctid"; then
      failed_containers+=("$ctid")
    fi
    # Graceful shutdown with timeout; force stop if needed
    if $DRY_RUN; then
      log_inf "[DRY-RUN] Would attempt graceful shutdown of $ctid (timeout ${SHUTDOWN_TIMEOUT}s)"
    else
      log_inf "Shutting down $ctid (timeout ${SHUTDOWN_TIMEOUT}s)"
      if ! timeout "$SHUTDOWN_TIMEOUT" pct shutdown "$ctid"; then
        log_err "Graceful shutdown timed out for $ctid, forcing stop"
        pct stop "$ctid" || true
      fi
    fi
  elif [[ "$status" == "status: running" ]]; then
    if ! update_container "$ctid"; then
      failed_containers+=("$ctid")
    fi
  else
    log_inf "Skipping template or unknown status for $ctid ($status)"
  fi

done < <(pct list | awk 'NR>1 {print $1}')

header_info
log_ok "All update attempts completed."

if ((${#containers_needing_reboot[@]})); then
  echo -e "${RD}Containers requiring reboot:${CL}"
  printf '%s\n' "${containers_needing_reboot[@]}"
  echo
fi

if ((${#failed_containers[@]})); then
  echo -e "${RD}Containers with update errors:${CL}"
  printf '%s\n' "${failed_containers[@]}"
  echo
  exit 1
fi

exit 0
