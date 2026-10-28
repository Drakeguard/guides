# Stalwart Mailserver mit Podman Quadlet (Rootless) – README

Dieses README dokumentiert die vollständige Einrichtung eines Stalwart-Mailservers als **rootless Podman-Quadlet** unter einem dedizierten Benutzer, mit **Caddy als Reverse-Proxy** für die WebUI, **manueller DNS-Verwaltung bei netcup** und einem **Vergleichsskript** zur Überwachung der DNS-Konfiguration.

---

## 1. Architekturübersicht

| Komponente | Lauf als | Netzwerk | Erreichbar über |
|---|---|---|---|
| Caddy | root (rootful) | `web`-Netzwerk | 80, 443 |
| Stalwart (WebUI) | `stalwart` (rootless) | pasta + `10.89.0.1:8080` | Caddy → `host.containers.internal:8080` |
| Stalwart (Mail) | `stalwart` (rootless) | pasta + Host-Ports | 25, 465, 587, 143, 993, 4190 (direkt) |

**Wichtig:** Caddy kann Mail-Ports nicht proxien (dafür wäre das `caddy-l4`-Plugin nötig). Stalwart terminiert TLS für die Mail-Ports selbst. Der WebUI-Zugriff läuft über Caddy (HTTPS) → Stalwart (HTTP auf `10.89.0.1:8080`).

---

## 2. Voraussetzungen

- VPS mit mindestens **2 GB RAM** (empfohlen: 4 GB) und **2 CPU-Kernen**
- **SELinux** aktiv (Standard bei vielen Distributionen)
- **Podman** ≥ 4.4 (Quadlet-Unterstützung)
- **Caddy** als rootful Container im `web`-Netzwerk (bereits vorhanden)
- **netcup**-DNS-Zone für die Domain
- **Port 25** ausgehend und eingehend freigegeben (beim VPS-Anbieter prüfen)
- **PTR-Reverse-DNS** auf den Mailserver-Hostnamen gesetzt

---

## 3. Benutzer und Verzeichnisse anlegen

Als root:

```bash
useradd -m -s /bin/bash stalwart
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 stalwart
loginctl enable-linger stalwart
```

`enable-linger` stellt sicher, dass die User-Quadlets auch ohne aktive Login-Session starten. Die Sub-UIDs sind für Rootless-Podman erforderlich.

Als `stalwart`:

```bash
su - stalwart
mkdir -p ~/.config/containers/systemd
mkdir -p ~/stalwart/data
mkdir -p ~/stalwart/config
```

---

## 4. Quadlet-Datei für Stalwart

Erstelle `~/.config/containers/systemd/stalwart.container`:

```ini
[Unit]
Description=Stalwart Mail Server (rootless)
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/stalwartlabs/stalwart:latest
ContainerName=stalwart

# Ressourcen-Limits: 2 GB RAM, 2 Kerne
PodmanArgs=--memory=2g --cpus=2

# Rootless mit keep-id: Host-User wird im Container zu Root
RemapUsers=keep-id

# Persistente Daten (RocksDB) und Konfiguration
Volume=%h/stalwart/data:/var/lib/stalwart:Z
Volume=%h/stalwart/config:/etc/stalwart:Z

# WebUI nur an Podman-Bridge binden (Caddy greift über host.containers.internal zu)
PublishPort=10.89.0.1:8080:8080

# Mail-Ports direkt an Host binden
PublishPort=0.0.0.0:25:25
PublishPort=0.0.0.0:465:465
PublishPort=0.0.0.0:587:587
PublishPort=0.0.0.0:143:143
PublishPort=0.0.0.0:993:993
PublishPort=0.0.0.0:4190:4190

# Öffentliche URL für OAuth/OIDC-WebUI-Anmeldung
Environment=STALWART_PUBLIC_URL=https://mail.maybusch.at

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

**Hinweis zu Port 25:** Rootless-Container können standardmäßig keine Ports unter 1024 binden. Falls der Start mit `Permission denied` fehlschlägt, muss `net.ipv4.ip_unprivileged_port_start=25` gesetzt werden (siehe Abschnitt 9).

---

## 5. Stalwart starten und Bootstrap-Modus

```bash
systemctl --user daemon-reload
systemctl --user start stalwart.service
```

Beim ersten Start findet Stalwart keine Konfiguration und startet im **Bootstrap-Modus**. Ein temporärer HTTP-Listener auf Port 8080 wird geöffnet.

**Bootstrap-Passwort aus den Logs holen:**

```bash
podman logs stalwart 2>&1 | grep -i "password\|admin"
```

Falls kein Passwort erscheint, setze `STALWART_RECOVERY_ADMIN` in der Quadlet-Datei und starte neu.

**Aufrufen:** `http://<stalwart-container-ip>:8080/admin`

Nach Abschluss des Einrichtungsassistenten **muss der Container neu gestartet werden** – Stalwart wechselt erst dann in den Normalbetrieb:

```bash
systemctl --user restart stalwart.service
```

---

## 6. Caddy-Konfiguration

In der Caddyfile (`/srv/caddy/Caddyfile`):

```caddyfile
mail.maybusch.at {
    reverse_proxy host.containers.internal:8080
}
```

Caddy neu laden:

```bash
sudo caddy reload --config /srv/caddy/Caddyfile
```

`host.containers.internal` löst im Caddy-Container auf die Podman-Bridge-Gateway-IP (`10.89.0.1`) auf, wo Stalwart lauscht.

**Nach dem Bootstrap:** Der HTTP-Block für den Bootstrap-Modus kann entfernt werden. Der HTTPS-Block bleibt für den WebUI-Zugriff bestehen.

---

## 7. DNS-Einträge bei netcup (manuelle Verwaltung)

Stalwart generiert eine vollständige Zonendatei. Da netcup keinen BIND-Zonendatei-Import unterstützt, müssen die Einträge **manuell im netcup CCP** angelegt werden.

**Zonendatei abrufen:** In der Stalwart-WebUI unter **Management › Domains › Domains** → Menü der Domain → **View Zone File**. Alternativ per CLI:

```bash
podman run --rm --network "container:stalwart" \
  ghcr.io/stalwartlabs/cli \
  --url "http://localhost:8080" --api-key "API_..." \
  get domain <domain-id> --fields dnsZoneFile
```

### Wichtige Einträge (Beispiele)

| Host | Typ | Destination / Inhalt | TTL |
|---|---|---|---|
| `@` | MX | `10 mail.maybusch.at.` | 3600 |
| `@` | TXT | `v=spf1 mx -all` | 3600 |
| `mail` | TXT | `v=spf1 a -all` | 3600 |
| `_dmarc` | TXT | `v=DMARC1; p=reject; rua=mailto:postmaster@maybusch.at` | 3600 |
| `v1-ed25519-...` | TXT | DKIM Ed25519 Public Key | 3600 |
| `v1-rsa-...` | TXT | DKIM RSA Public Key (mehrzeilig) | 3600 |
| `_imaps._tcp` | SRV | `0 1 993 mail.maybusch.at.` | 3600 |
| `mta-sts` | CNAME | `mail.maybusch.at.` | 3600 |
| `_mta-sts` | TXT | `v=STSv1; id=...` | 300 |

**SRV-Einträge bei netcup:** Alle vier Werte (Priorität, Gewichtung, Port, Zielhost) müssen zusammen im Feld **„Destination"** eingegeben werden, z. B. `0 1 993 mail.maybusch.at.` (mit abschließendem Punkt).

**CAA-Einträge:** Netcup akzeptiert CAA-Einträge. Falls die Eingabe mit Anführungszeichen fehlschlägt, ohne Anführungszeichen versuchen.

**Wichtig:** Stelle sicher, dass der **A-Record** für `mail.maybusch.at` auf die VPS-IP zeigt, bevor die MX-Zustellung funktioniert.

---

## 8. DNS-Vergleichsskript

Das Skript vergleicht die von Stalwart generierte Zonendatei mit den live bei netcup veröffentlichten Einträgen.

### Skript: `check-dns.sh`

```bash
#!/usr/bin/env bash
# check-dns.sh - Fetches the zone file from Stalwart and compares it with live DNS
# Usage: STALWART_API_KEY='API_...' ./check-dns.sh [resolver]

set -uo pipefail

DOMAIN="${DOMAIN:-maybusch.at}"
DOMAIN_ID="${DOMAIN_ID:-b}"
STALWART_CONTAINER="${STALWART_CONTAINER:-stalwart}"
CLI_IMAGE="${CLI_IMAGE:-ghcr.io/stalwartlabs/cli}"
API_KEY="${STALWART_API_KEY:-}"
RESOLVER="${1:-}"

die() { echo "Fehler: $*" >&2; exit 1; }

[[ -n "$API_KEY" ]] || {
    echo "Usage: STALWART_API_KEY='API_...' $0 [resolver]" >&2
    die "STALWART_API_KEY nicht gesetzt."
}
command -v dig >/dev/null || die "dig nicht gefunden."

DIG=(dig +time=3 +tries=2)
[[ -n "$RESOLVER" ]] && DIG+=("@$RESOLVER")

fetch_zone() {
    podman run --rm \
        --network "container:${STALWART_CONTAINER}" \
        "$CLI_IMAGE" \
        --url "http://localhost:8080" \
        --api-key "$API_KEY" \
        get domain "$DOMAIN_ID" --fields dnsZoneFile \
    | awk 'f { sub(/^    /, ""); print } /DNS Zone File:/ { f=1 }'
}

normalize_zone() {
    awk '
        /^[[:space:]]*(;|$)/ { next }
        {
            buf = buf " " $0
            tmp = $0
            depth += gsub(/\(/, "", tmp)
            depth -= gsub(/\)/, "", tmp)
            if (depth > 0) next
            line = buf; buf = ""; depth = 0
            gsub(/[()]/, " ", line)
            gsub(/"[[:space:]]+"/, "", line)
            gsub(/"/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            sub(/^ /, "", line); sub(/ $/, "", line)
            print line
        }'
}

echo "=== Hole Zonendatei aus Stalwart (Domain-ID: $DOMAIN_ID) ==="
ZONE_RAW=$(fetch_zone) || die "CLI-Aufruf fehlgeschlagen."
[[ -n "$ZONE_RAW" ]]   || die "Zonendatei ist leer."
ZONE=$(normalize_zone <<<"$ZONE_RAW")
echo "Zonendatei empfangen ($(wc -l <<<"$ZONE_RAW") Zeilen, $(wc -l <<<"$ZONE") Records)."
echo

norm() {
    sed -e 's/" "//g' -e 's/"//g' \
        -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' \
        -e 's/\.$//' | sort
}

zone_values() {
    awk -v n="$1" -v t="$2" '
        {
            for (i = 1; i <= NF; i++) if ($i == "IN") break
            if (i >= NF - 1) next
            h = $1; sub(/\.$/, "", h)
            if (h == n && $(i+1) == t) {
                s = $(i+2)
                for (j = i+3; j <= NF; j++) s = s " " $j
                print s
            }
        }' <<<"$ZONE"
}

zone_names() {
    awk -v t="$1" -v re="$2" '
        {
            for (i = 1; i <= NF; i++) if ($i == "IN") break
            if (i >= NF - 1 || $(i+1) != t) next
            h = $1; sub(/\.$/, "", h)
            if (h ~ re) print h
        }' <<<"$ZONE" | sort -u
}

live_values() {
    local host="$1" type="$2"
    if [[ "$type" == "SRV" ]]; then
        "${DIG[@]}" +noall +answer "$host" SRV 2>/dev/null \
            | awk '$4 == "SRV" { print $5, $6, $7, $8 }'
    else
        "${DIG[@]}" +short "$host" "$type" 2>/dev/null
    fi
}

MISMATCHES=0

check() {
    local label="$1" name="$2" type="$3" filter="${4:-}"
    local zone live
    zone=$(zone_values "$name" "$type" | norm)
    live=$(live_values "$name" "$type" | norm)
    if [[ -n "$filter" ]]; then
        zone=$(grep -E -- "$filter" <<<"$zone" || true)
        live=$(grep -E -- "$filter" <<<"$live" || true)
    fi

    if [[ -z "$zone" && -z "$live" ]]; then
        echo "⏭️  $label (beide leer – prüfen)"
    elif [[ "$type" == "SRV" && -z "$live" ]]; then
        echo "⏭️  $label (live nicht auflösbar – Resolver blockiert SRV oder Record fehlt)"
    elif [[ "$zone" == "$live" ]]; then
        echo "✅ $label"
    else
        echo "❌ $label"
        echo "   Zonendatei: '$(tr '\n' ' ' <<<"$zone" | sed 's/ $//')'"
        echo "   Live DNS:   '$(tr '\n' ' ' <<<"$live" | sed 's/ $//')'"
        MISMATCHES=$((MISMATCHES + 1))
    fi
}

section() { echo; echo "--- $1 ---"; }

echo "=== DNS-Abgleich für $DOMAIN (Resolver: ${RESOLVER:-lokal}) ==="

section MX
check "MX $DOMAIN" "$DOMAIN" MX

section TXT
check "SPF (Apex)"   "$DOMAIN"                  TXT 'v=spf1'
check "SPF (mail)"   "mail.$DOMAIN"             TXT 'v=spf1'
check "DMARC"        "_dmarc.$DOMAIN"           TXT
check "MTA-STS TXT"  "_mta-sts.$DOMAIN"         TXT
check "TLS-RPT"      "_smtp._tls.$DOMAIN"       TXT
check "UAAC"         "_ua-auto-config.$DOMAIN"  TXT

dkim_found=0
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dkim_found=1
    check "DKIM ${name%%._domainkey*}" "$name" TXT
done < <(zone_names TXT '\._domainkey\.')
(( dkim_found )) || echo "⏭️  DKIM (keine Selektoren in der Zonendatei gefunden)"

section CNAME
for host in mta-sts ua-auto-config autoconfig autodiscover; do
    check "CNAME $host" "$host.$DOMAIN" CNAME
done

section SRV
for srv in _caldavs._tcp _carddavs._tcp _imaps._tcp _jmap._tcp _pop3s._tcp _submissions._tcp; do
    check "SRV $srv" "$srv.$DOMAIN" SRV
done

section CAA
check "CAA issue"  "$DOMAIN" CAA '^0 issue '
check "CAA iodef"  "$DOMAIN" CAA '^0 iodef '

echo
echo "============================================"
if (( MISMATCHES == 0 )); then
    echo "✅ Alle geprüften Einträge stimmen überein."
else
    echo "❌ $MISMATCHES Abweichung(en) gefunden."
    exit 1
fi
```

### Verwendung

```bash
chmod +x check-dns.sh
STALWART_API_KEY='API_...' ./check-dns.sh
```

**Hinweis zu SRV:** Wenn der lokale Resolver SRV-Abfragen blockiert (häufig bei VPS-Anbietern), werden die SRV-Records als `⏭️` markiert. Sie sind für den Mailbetrieb nicht kritisch – nur für die Auto-Discovery von Mail-Clients. Manuelle Prüfung über `dig +noall +answer _imaps._tcp.maybusch.at SRV @ns1.netcup.net` oder ein Web-Tool wie MXToolbox.

---

## 9. Fehlerbehebung

### Port 25: Permission denied (rootless)

Rootless-Container können keine Ports unter 1024 binden. Lösung als root:

```bash
echo "net.ipv4.ip_unprivileged_port_start=25" > /etc/sysctl.d/99-podman-privileged-ports.conf
sysctl --system
```

Alternativ: `setcap cap_net_bind_service=+ep /usr/lib/podman/rootlessport` (inoffiziell, aber granularer).

### WebUI: „Client metadata documents are disabled"

Stalwart muss seinen öffentlichen Hostnamen kennen. Stelle sicher, dass `STALWART_PUBLIC_URL=https://mail.maybusch.at` in der Quadlet-Datei gesetzt ist.

### WebUI: „Empty reply from server"

Häufigste Ursache: Stalwart hat die IP des Docker-Bridge-Netzwerks blockiert. Lösung: Recovery-Modus aktivieren, Blockliste unter **Settings → Security → Blocked IPs** bereinigen, `10.89.0.1` zu **Allowed IPs** hinzufügen.

### WebUI: Nach Bootstrap nicht erreichbar

Stalwart läuft nach dem Assistenten weiterhin im Bootstrap-Modus, bis der Container **neu gestartet** wird. Führe `systemctl --user restart stalwart.service` aus.

### Logs sind leer (`podman logs stalwart`)

Der Standard-Tracer schreibt in eine Datei, die im Container nicht existiert. Setze in der Quadlet-Datei: `Environment=STALWART_LOG=console` (oder äquivalent, je nach Stalwart-Version).

---

## 10. Wartung und Backup

**RocksDB-Backup:** Die einzige zuverlässige Methode für RocksDB ist ein **Filesystem-Snapshot oder eine Kopie des Datenverzeichnisses bei gestopptem Server**. Der eingebaute Export/Import ist **kein Backup** für einen laufenden Server, sondern ein Migrationswerkzeug.

```bash
systemctl --user stop stalwart.service
tar -czf ~/stalwart-backup-$(date +%F).tar.gz -C ~/stalwart data/
systemctl --user start stalwart.service
```

**DKIM-Rotation:** Nach einer DKIM-Schlüsselrotation ändert sich die Zonendatei. Das Vergleichsskript zeigt die Abweichung an. Aktualisiere den neuen DKIM-TXT-Record bei netcup manuell.

**MTA-STS-ID:** Ändert sich die MTA-STS-Policy-ID, muss der `_mta-sts`-TXT-Record aktualisiert werden (TTL 300 empfohlen für schnelle Propagation).

---

## 11. Wichtige Referenzen

- **Stalwart Docker-Dokumentation:** Bootstrap-Modus, WebUI-Zugriff, Neustart nach Assistent
- **Stalwart DNS-Dokumentation:** Zonendatei, manuelle vs. automatische Verwaltung
- **Stalwart Caddy-Integration:** Reverse-Proxy, TLS-Terminierung, `STALWART_PUBLIC_URL`
- **Stalwart Backup/Storage:** RocksDB-Backup, Blob-Purge
- **Podman Rootless:** Sub-UIDs, `enable-linger`, Port-Beschränkungen
- **netcup libdns:** TTL-Beschränkung (keine individuellen TTLs pro Record)
