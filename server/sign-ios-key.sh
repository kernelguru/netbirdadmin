#!/usr/bin/env bash
# Signiert den Public Key der iOS-App mit der NetBird-Admin-CA.
#   ./sign-ios-key.sh <public-key-datei> [principal] [gültigkeit]
# Beispiel: ./sign-ios-key.sh netbird-ios.pub netbird-admin +52w
# Ergebnis: <datei>-cert.pub -> Inhalt in der App unter Server → SSH-Zertifikat importieren.
set -euo pipefail
PUB="${1:?Public-Key-Datei angeben}"
PRINCIPAL="${2:-netbird-admin}"
VALIDITY="${3:-+52w}"
CA="${CA_KEY:-/etc/ssh/netbird_admin_ca}"
SERIAL="$(date +%s)"

ssh-keygen -s "$CA" -I "netbird-admin-ios-$SERIAL" -n "$PRINCIPAL" -V "$VALIDITY" -z "$SERIAL" "$PUB"
CERT="${PUB%.pub}-cert.pub"
echo
ssh-keygen -Lf "$CERT"
echo
echo "---- in die App kopieren ----"
cat "$CERT"
