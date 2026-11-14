# NetBird Admin für iOS

Native SwiftUI-App zur Administration eines (selbst gehosteten) **NetBird**-Servers – im Stil von Pangolin Admin, mit **Liquid-Glass-UI** (iOS 26, Fallback auf Material-Glas ab iOS 17).

## Funktionen

| Bereich | Was geht |
|---|---|
| **Übersicht** | Clients online/gesamt, Exit-Nodes, Proxy-Services, gültige Setup-Keys, offizielles Release vs. veraltete Clients |
| **Clients** | Status (online, zuletzt gesehen, IPv4 **und IPv6**, Version, OS, Standort), Filter/Suche, umbenennen, SSH-Server / Login-Ablauf schalten, entfernen |
| **Neue Clients** | Setup-Key anlegen (einmalig/wiederverwendbar, Gültigkeit, Limit, ephemer, Auto-Gruppen) → Key im Klartext, **QR-Code**, fertige `netbird up`- und Docker-Befehle. Keys widerrufen/löschen |
| **Reverse Proxy** | NetBird-Reverse-Proxy-Services anzeigen (Status, Zertifikat, Ziele), **an/aus schalten**, anlegen (HTTP/TCP/UDP/TLS → Peer oder Host), löschen; Proxy-Cluster-Status; eigene Domains hinzufügen und validieren |
| **Exit-Nodes** | Anlegen mit **IPv4 (0.0.0.0/0) + IPv6 (::/0)**, aktivieren/deaktivieren, Auto-Apply, IPv6 nachrüsten, löschen |
| **IPv6** | IPv6-Overlay aktivieren/deaktivieren (`ipv6_enabled_groups`), eigener ULA-Bereich (`network_range_v6`) |
| **Server-Update** | Vergleicht das **offizielle GitHub-Release** (`netbirdio/netbird`) mit der lokalen Version (per SSH bzw. `/api/instance/version`) und aktualisiert per **SSH mit Zertifikat als root** – Live-Log |
| **SSH-Konsole** | Schnellbefehle (Container, Logs, Neustart, IPv6-Check) und freie Befehle |
| **Mehrere Server** | beliebig viele Profile, Secrets in der Keychain |

## Build

```bash
brew install xcodegen
xcodegen generate
open NetBirdAdmin.xcodeproj
```

Benötigt Xcode 16+ (Xcode 26 für Liquid Glass). Abhängigkeit: [Citadel](https://github.com/orlandos-nl/Citadel) (SSH, via SwiftPM). In Xcode unter *Signing & Capabilities* das eigene Team wählen.
Die GitHub-Action `.github/workflows/ios-build.yml` baut die App bei jedem Push für den Simulator.

## Einrichtung

### 1. API-Token
NetBird-Dashboard → **Team → Service Users** → Service-User mit Rolle *Admin* → **Token erstellen**.
In der App: *Server → Server hinzufügen* → Management-URL (z. B. `https://netbird.example.com`) + Token.

### 2. SSH-Zertifikat mit Principals (root-Login)

Die App meldet sich mit einem **OpenSSH-User-Zertifikat** an. sshd vertraut der CA; welcher Principal sich als welcher Benutzer anmelden darf, steht in `/etc/ssh/auth_principals/<user>`. So kann sich das Zertifikat mit Principal `netbird-admin` direkt als **root** anmelden – ohne dass ein Schlüssel in `authorized_keys` liegt.

Auf dem Server (einmalig):

```bash
sudo ./server/setup-ssh-ca.sh                    # CA erzeugen, Principal "netbird-admin" → root
# empfohlen: CA offline halten und nur den Public Key übergeben
sudo ./server/setup-ssh-ca.sh -c ./netbird_admin_ca.pub -p netbird-admin
```

Das Skript setzt:

```
TrustedUserCAKeys /etc/ssh/netbird_admin_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u   # root → netbird-admin
PermitRootLogin prohibit-password                     # root nur mit Key/Zertifikat
```

In der App: *Server → SSH-Zertifikat*

1. **Ed25519-Schlüssel erzeugen** (bleibt in der Keychain, nur dieses Gerät).
2. Public Key kopieren/teilen und signieren – die App zeigt den passenden Befehl:
   ```bash
   ./server/sign-ios-key.sh netbird-ios.pub netbird-admin +52w
   ```
3. Inhalt von `netbird-ios-cert.pub` in der App **importieren**. Die App zeigt Key-ID, Principals und Gültigkeit an und prüft, dass das Zertifikat zum Schlüssel passt.

Beim ersten Verbinden wird der **Host-Key-Fingerprint** angezeigt (Trust on first use) – mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` vergleichen. Ändert er sich später, verweigert die App die Verbindung.

### 3. Update-Methoden

* **Docker Compose** (Standard): im Installationsverzeichnis (Standard `/opt/netbird`) wird die Compose-Datei gesichert, die `netbirdio/*`-Images (management, signal, relay, …) auf das neue Release gesetzt (`dashboard` → `latest`), `docker compose pull && up -d` ausgeführt.
* **Eigener Befehl**: beliebiges Skript, Platzhalter `{{version}}` (`0.60.1`) und `{{tag}}` (`v0.60.1`). Beispiel für Binary-Installationen:
  ```bash
  apt-get update && apt-get install -y netbird && systemctl restart netbird
  ```

## IPv6

Aktuelle NetBird-Versionen vergeben IPv6-Overlay-Adressen an Peers in den Gruppen aus `ipv6_enabled_groups`. Die App zeigt die IPv6-Adresse jedes Clients, kann das Overlay ein-/ausschalten und legt Exit-Nodes auf Wunsch zusätzlich als `::/0`-Route an. Ältere Server ohne IPv6-Support ignorieren die Felder – die App funktioniert dann wie gewohnt mit IPv4.

## Sicherheit

* API-Token, privater SSH-Schlüssel und Zertifikat liegen in der iOS-Keychain (`WhenUnlockedThisDeviceOnly`).
* Zertifikate mit kurzer Laufzeit (`-V +4w`) ausstellen und bei Verlust des Geräts die Principal-Datei leeren oder die CA rotieren; alternativ `RevokedKeys` in sshd nutzen.
* Die CA-Private-Key sollte idealerweise **nicht** auf dem NetBird-Server liegen (`-c` Option).

## Projektstruktur

```
project.yml                  XcodeGen-Projekt
NetBirdAdmin/
  App/                       App-Einstieg, Tabs
  Models/                    API-Modelle, Server-Profil, JSONValue
  Services/                  NetBird-API, GitHub-Releases, SSH (Citadel), Updater, Keychain
  UI/Glass.swift             Liquid-Glass-Komponenten
  Views/                     Übersicht, Clients, Setup-Keys, Reverse Proxy, Netzwerk/Exit-Nodes/IPv6, Server/Update/SSH
server/
  setup-ssh-ca.sh            sshd für Zertifikats-Login (Principals → root) einrichten
  sign-ios-key.sh            Public Key der App signieren
```
