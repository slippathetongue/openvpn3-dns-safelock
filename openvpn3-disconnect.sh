#!/usr/bin/env bash
set -euo pipefail

# Disconnect OpenVPN 3 sessions and restore /etc/resolv.conf from backup.

BACKUP_FILE="/etc/resolv.conf.vpn3backup"
LOCK_DIR="/run/openvpn3-locked.d"
LOCK_FLAG="${LOCK_DIR}/dnslock"

echo "[+] openvpn3-disconnect.sh starting"

# --- sanity checks ----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "[!] This script must be run as root" >&2
  exit 1
fi

if ! command -v openvpn3 >/dev/null 2>&1; then
  echo "[!] openvpn3 command not found in PATH (will only handle DNS restore)" >&2
fi

# --- helpers to talk to user/root OpenVPN 3 contexts -----------------------

disconnect_in_context() {
  local ctx="$1"    # "user" or "root"
  local session_path=""

  if ! command -v openvpn3 >/dev/null 2>&1; then
    return 1
  fi

  if [[ "$ctx" == "user" ]]; then
    if [[ -z "${SUDO_USER-}" ]]; then
      return 1
    fi
    session_path="$(sudo -u "$SUDO_USER" openvpn3 sessions-list 2>/dev/null | \
      grep -o '/net/openvpn/v3/sessions/[^ ]*' | head -n1 || true)"
    if [[ -z "$session_path" ]]; then
      return 1
    fi
    echo "[+] Active OpenVPN 3 session found for user '$SUDO_USER': $session_path"
    echo "[+] Disconnecting user session..."
    if sudo -u "$SUDO_USER" openvpn3 session-manage --session-path "$session_path" --disconnect; then
      echo "[+] User session disconnected successfully"
      return 0
    else
      echo "[!] Failed to disconnect user session (check openvpn3 logs)"
      return 1
    fi
  else
    session_path="$(openvpn3 sessions-list 2>/dev/null | \
      grep -o '/net/openvpn/v3/sessions/[^ ]*' | head -n1 || true)"
    if [[ -z "$session_path" ]]; then
      return 1
    fi
    echo "[+] Active OpenVPN 3 session found for root: $session_path"
    echo "[+] Disconnecting root session..."
    if openvpn3 session-manage --session-path "$session_path" --disconnect; then
      echo "[+] Root session disconnected successfully"
      return 0
    else
      echo "[!] Failed to disconnect root session (check openvpn3 logs)"
      return 1
    fi
  fi
}

# --- disconnect any active sessions (user first, then root) ----------------

disconnected=0

if [[ -n "${SUDO_USER-}" ]]; then
  if disconnect_in_context "user"; then
    disconnected=1
  fi
fi

if [[ $disconnected -eq 0 ]]; then
  if disconnect_in_context "root"; then
    disconnected=1
  fi
fi

if [[ $disconnected -eq 0 ]]; then
  echo "[+] No active OpenVPN 3 sessions found for user or root"
fi

# --- restore resolv.conf from backup ---------------------------------------

if [[ -f "$BACKUP_FILE" ]]; then
  echo "[+] Backup file found: $BACKUP_FILE"

  echo "[+] Removing immutable flag on /etc/resolv.conf (if set)"
  chattr -i /etc/resolv.conf 2>/dev/null || true

  echo "[+] Restoring /etc/resolv.conf from backup"
  cp -f "$BACKUP_FILE" /etc/resolv.conf

  echo "[+] Removing backup file $BACKUP_FILE"
  rm -f "$BACKUP_FILE"

  if [[ -e "$LOCK_FLAG" ]]; then
    echo "[+] Clearing DNS lock flag $LOCK_FLAG"
    rm -f "$LOCK_FLAG" 2>/dev/null || true
  fi

  echo "[+] Re-applying permissions on /etc/resolv.conf"
  chown root:root /etc/resolv.conf 2>/dev/null || true
  chmod 644 /etc/resolv.conf 2>/dev/null || true

  echo "[+] DNS configuration restored to pre-VPN state"
else
  echo "[+] No backup file ($BACKUP_FILE) found; nothing to restore"
fi

echo "[+] openvpn3-disconnect.sh done"
