#!/usr/bin/env bash
set -euo pipefail

# Start an OpenVPN 3 session and lock /etc/resolv.conf to the VPN DNS.

BACKUP="/etc/resolv.conf.vpn3backup"
LOCK_DIR="/run/openvpn3-locked.d"
LOCK_FLAG="${LOCK_DIR}/dnslock"

echo "[+] openvpn3-connect.sh starting"

# --- sanity checks ----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "[!] This script must be run as root" >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "[!] Missing OpenVPN 3 profile name argument" >&2
  exit 1
fi

PROFILE="$1"
OWNER="${SUDO_USER:-$(id -un)}"

echo "[+] Using profile '$PROFILE' for user '$OWNER'"

if [[ ! -e /etc/resolv.conf ]]; then
  echo "[!] /etc/resolv.conf not found" >&2
  exit 1
fi

# Expect a regular file, not a systemd-resolved or resolvconf symlink.
if [[ -L /etc/resolv.conf ]]; then
  echo "[!] /etc/resolv.conf is a symlink; expected a regular file" >&2
  echo "[!] Aborting to avoid breaking existing resolver setup" >&2
  exit 1
fi

# Refuse to run if resolv.conf is already immutable.
if command -v lsattr >/dev/null 2>&1; then
  if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    echo "[!] /etc/resolv.conf is already immutable; refusing to modify it" >&2
    exit 1
  fi
fi

if [[ -e "$BACKUP" ]]; then
  echo "[!] Backup $BACKUP already exists"
  echo "[!] Previous run likely did not restore it; aborting"
  exit 1
fi

mkdir -p "$LOCK_DIR"

if ! command -v openvpn3 >/dev/null 2>&1; then
  echo "[!] openvpn3 command not found in PATH" >&2
  exit 1
fi

# --- backup current resolv.conf --------------------------------------------

echo "[+] Backing up /etc/resolv.conf to $BACKUP"
cp /etc/resolv.conf "$BACKUP"

# --- start OpenVPN 3 session -----------------------------------------------

echo "[+] Starting OpenVPN 3 session"
# Run as the non-root profile owner so user profiles are resolved correctly.
if ! sudo -u "$OWNER" openvpn3 session-start --config "$PROFILE"; then
  echo "[!] openvpn3 session-start failed; restoring original /etc/resolv.conf"
  cp "$BACKUP" /etc/resolv.conf
  rm -f "$BACKUP"
  exit 1
fi

# --- extract VPN DNS block --------------------------------------------------

echo "[+] Waiting for VPN DNS entries to appear in /etc/resolv.conf..."
VPN_NS=""

# Give NetCfg some time to write the OpenVPN DNS section.
for _ in {1..10}; do
  VPN_NS="$(awk '
    /^# OpenVPN defined name servers/ {flag=1; next}
    (/^# System defined name servers/ || /^$/) {flag=0}
    flag && /^nameserver/ {print}
  ' /etc/resolv.conf || true)"

  if [[ -n "$VPN_NS" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$VPN_NS" ]]; then
  echo "[!] Could not find OpenVPN-defined nameservers in /etc/resolv.conf"
  echo "[+] Restoring original /etc/resolv.conf from backup"
  if [[ -e "$BACKUP" ]]; then
    cp "$BACKUP" /etc/resolv.conf
    rm -f "$BACKUP"
  fi
  exit 1
fi

# --- lock resolv.conf to VPN DNS -------------------------------------------

echo "[+] Locking /etc/resolv.conf to VPN DNS only"
cat > /etc/resolv.conf <<EOF
# resolv.conf locked by openvpn3-connect.sh at $(date -Is)
# Original file backed up at: $BACKUP

$VPN_NS
EOF

# Try to prevent NetworkManager / DHCP / netcfg from touching resolv.conf.
if ! chattr +i /etc/resolv.conf 2>/dev/null; then
  echo "[!] Warning: failed to set immutable flag on /etc/resolv.conf (chattr +i)"
fi

touch "$LOCK_FLAG"

echo
echo "[+] DNS is now locked to the following VPN nameservers:"
echo "$VPN_NS"
echo
echo "[+] openvpn3-connect.sh done"
