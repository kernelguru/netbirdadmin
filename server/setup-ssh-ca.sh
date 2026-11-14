#!/usr/bin/env bash
# Richtet auf dem NetBird-Server die SSH-Zertifikats-Anmeldung für die iOS-App ein.
#
#  * legt (optional) eine SSH-User-CA an  -> /etc/ssh/netbird_admin_ca[.pub]
#  * sshd vertraut dieser CA              -> TrustedUserCAKeys
#  * Principal-Zuordnung pro Benutzer     -> /etc/ssh/auth_principals/<user>
#  * root darf sich NUR per Key/Zertifikat anmelden (PermitRootLogin prohibit-password)
#
# Nutzung:
#   sudo ./setup-ssh-ca.sh                       # CA auf diesem Server erzeugen, Principal "netbird-admin"
#   sudo ./setup-ssh-ca.sh -p ops -p netbird-admin
#   sudo ./setup-ssh-ca.sh -c /pfad/ca.pub       # vorhandene (offline gehaltene) CA verwenden – empfohlen
set -euo pipefail

CA_KEY=/etc/ssh/netbird_admin_ca
CA_PUB=""
PRINCIPALS=()
TARGET_USER=root

while getopts "c:p:u:h" opt; do
  case $opt in
    c) CA_PUB="$OPTARG" ;;
    p) PRINCIPALS+=("$OPTARG") ;;
    u) TARGET_USER="$OPTARG" ;;
    h|*) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done
[ ${#PRINCIPALS[@]} -eq 0 ] && PRINCIPALS=(netbird-admin)
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root ausführen"; exit 1; }

if [ -z "$CA_PUB" ]; then
  if [ ! -f "$CA_KEY" ]; then
    ssh-keygen -t ed25519 -f "$CA_KEY" -N "" -C "netbird-admin-user-ca@$(hostname)"
    chmod 600 "$CA_KEY"
    echo "✓ CA erzeugt: $CA_KEY  (privaten Schlüssel gut schützen / besser offline lagern!)"
  fi
  CA_PUB="$CA_KEY.pub"
else
  install -m 644 "$CA_PUB" "$CA_KEY.pub"
  CA_PUB="$CA_KEY.pub"
fi

install -d -m 755 /etc/ssh/auth_principals
printf '%s\n' "${PRINCIPALS[@]}" > "/etc/ssh/auth_principals/$TARGET_USER"
chmod 644 "/etc/ssh/auth_principals/$TARGET_USER"
echo "✓ Principals für $TARGET_USER: ${PRINCIPALS[*]}"

CONF_SNIPPET="# --- NetBird Admin iOS (Zertifikats-Login) ---
TrustedUserCAKeys $CA_PUB
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PubkeyAcceptedAlgorithms +ssh-ed25519-cert-v01@openssh.com"

if grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config && [ -d /etc/ssh/sshd_config.d ]; then
  # 00-… damit unsere Werte vor distributionsspezifischen Defaults gelten (sshd: first match wins)
  echo "$CONF_SNIPPET" > /etc/ssh/sshd_config.d/00-netbird-admin.conf
  echo "✓ /etc/ssh/sshd_config.d/00-netbird-admin.conf geschrieben"
else
  if ! grep -q "NetBird Admin iOS" /etc/ssh/sshd_config; then
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%s)"
    { echo "$CONF_SNIPPET"; echo; cat /etc/ssh/sshd_config; } > /etc/ssh/sshd_config.new
    mv /etc/ssh/sshd_config.new /etc/ssh/sshd_config
    echo "✓ Konfiguration an den Anfang von /etc/ssh/sshd_config gesetzt"
  fi
fi

sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload
echo "✓ sshd neu geladen"
echo
echo "Host-Key-Fingerprint (in der App vergleichen):"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub || true
echo
echo "Public Key aus der App signieren:"
echo "  ./sign-ios-key.sh netbird-ios.pub ${PRINCIPALS[0]} +52w"
