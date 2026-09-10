# Complete Guide: Hardened Headscale + Caddy on Podman with Btrfs (Debian 13)

### Assumed specs
1 vCPU, 1 GB RAM, 30 GB HDD, AMD64, Debian 13 (Trixie)

---

## 1. Install Podman

```bash
apt update
apt install -y podman crun uidmap fuse-overlayfs
podman --version
```

---

## 2. Subuid/subgid ranges (required for `UserNS=auto`)

```bash
grep -q "^containers:" /etc/subuid || echo "containers:100000:65536" >> /etc/subuid
grep -q "^containers:" /etc/subgid || echo "containers:100000:65536" >> /etc/subgid
```

---

## 3. Btrfs subvolumes

Check layout:

```bash
btrfs subvolume list /
blkid | grep -i btrfs
```

### App configs/data (one shared subvolume)

```bash
mkdir -p /srv
btrfs subvolume create /srv/appdata

mkdir -p \
  /srv/appdata/headscale/config \
  /srv/appdata/headscale/data \
  /srv/appdata/caddy/config \
  /srv/appdata/caddy/data
```

### Podman container storage (separate subvolume, NoCOW)

Stop Podman first, and make sure nothing is running:

```bash
podman ps -a
systemctl stop podman podman.socket 2>/dev/null

mv /var/lib/containers /var/lib/containers.bak
btrfs subvolume create /var/lib/containers
chattr +C /var/lib/containers
rsync -aAXv /var/lib/containers.bak/ /var/lib/containers/
rm -rf /var/lib/containers.bak
```

> `chattr +C` (NoCOW) and Btrfs `compress=zstd` are mutually exclusive in practice — NoCOW wins and compression is ignored. Since NoCOW is better for overlay/DB-style writes, do **not** set `compress=zstd` on this mount; keep compression only on `/srv/appdata`.

### `/etc/fstab`

```
UUID=<BTRFS_UUID>  /srv/appdata         btrfs  subvol=srv/appdata,compress=zstd,noatime  0 0
UUID=<BTRFS_UUID>  /var/lib/containers  btrfs  subvol=var/lib/containers,noatime         0 0
```

```bash
systemctl daemon-reload
mount -a
mount | grep -E "appdata|containers"
```

### Podman storage config

```bash
nano /etc/containers/storage.conf
```

```ini
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
```

Restart Podman and verify:

```bash
systemctl start podman podman.socket 2>/dev/null
podman info --debug | grep -A5 store
podman ps
```

---

## 4. Podman network (Quadlet)

```bash
nano /etc/containers/systemd/web.network
```

```ini
[Network]
NetworkName=web
```

```bash
systemctl daemon-reload
systemctl start web-network.service
podman network ls
```

(This unit is transient/generated — it can't be `enable`d; containers depend on it via `Requires=`/`After=` instead.)

---

## 5. Headscale config

```bash
nano /srv/appdata/headscale/config/config.yaml
```

```yaml
server_url: https://headscale.yourdomain.com

listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090

noise:
  private_key_path: /var/lib/headscale/noise_private.key

derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 24h

database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite
```

> `listen_addr` **must** be `0.0.0.0:8080` (not `127.0.0.1:8080`), otherwise Caddy in a separate container cannot reach Headscale over the internal network. Keep `metrics_listen_addr` on loopback — it doesn't need external exposure.

---

## 6. Headscale ACL policy

```bash
nano /srv/appdata/headscale/config/policy.hujson
```

```json
{
  "groups": {
    "group:admins": ["admin@"],
    "group:personal": ["personal@"],
    "group:guests": ["guest@"]
  },

  "tagOwners": {
    "tag:admin-device": ["group:admins"],
    "tag:server": ["group:admins"],
    "tag:media": ["group:admins"],
    "tag:monitoring": ["group:admins"],
    "tag:guest-device": ["group:admins"]
  },

  "acls": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["*:*"]
    },
    {
      "action": "accept",
      "src": ["group:personal"],
      "dst": [
        "tag:server:22,80,443",
        "tag:media:8096",
        "tag:monitoring:3000"
      ]
    },
    {
      "action": "accept",
      "src": ["group:guests"],
      "dst": ["tag:media:8096"]
    },
    {
      "action": "accept",
      "src": ["tag:server"],
      "dst": [
        "tag:server:22",
        "tag:monitoring:9090"
      ]
    }
  ],

  "ssh": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["tag:server"],
      "users": ["root", "autogroup:nonroot"]
    }
  ]
}
```

> Group members must match Headscale's internal identifier format. A local user with no email (e.g. `admin`) is represented as `admin@` (no domain). Confirm actual usernames with `headscale users list` before editing.

---

## 7. Headscale Quadlet (hardened)

```bash
nano /etc/containers/systemd/headscale.container
```

```ini
[Unit]
Description=Headscale Coordination Server
Requires=web-network.service
After=network-online.target web-network.service

[Container]
Image=docker.io/headscale/headscale:0.29.3
ContainerName=headscale
Exec=serve
Network=web.network

UserNS=auto
DropCapability=ALL
NoNewPrivileges=true
ReadOnly=true

Tmpfs=/tmp:rw,mode=1777
Tmpfs=/var/run/headscale:rw,mode=0755

Volume=/srv/appdata/headscale/config:/etc/headscale:Z,U
Volume=/srv/appdata/headscale/data:/var/lib/headscale:Z,U

AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

> Pin to a specific version tag (e.g. `0.29.3`) rather than `:latest` — auto-updates previously broke the config schema (noise key path, policy format, DERP map) across versions. Upgrade deliberately after reading release notes.

```bash
systemctl daemon-reload
systemctl enable --now headscale.service
```

---

## 8. Caddy config

```bash
nano /srv/appdata/caddy/config/Caddyfile
```

```caddyfile
headscale.yourdomain.com {
    reverse_proxy headscale:8080
}
```

---

## 9. Caddy Quadlet

```bash
nano /etc/containers/systemd/caddy.container
```

```ini
[Unit]
Description=Caddy Reverse Proxy
Requires=web-network.service
After=network-online.target web-network.service

[Container]
Image=docker.io/library/caddy:latest
ContainerName=caddy
Network=web.network

Volume=/srv/appdata/caddy/config/Caddyfile:/etc/caddy/Caddyfile:Z
Volume=/srv/appdata/caddy/data:/data:Z,U

PublishPort=80:80
PublishPort=443:443

AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now caddy.service
```

---

## 10. DNS

Point an A/AAAA record for `headscale.yourdomain.com` to your VPS's public IP (required for Caddy's automatic Let's Encrypt certificate).

---

## 11. Verify everything

```bash
systemctl status --no-pager -l headscale.service
systemctl status --no-pager -l caddy.service

podman ps --format "{{.Names}} {{.Networks}}"
podman network inspect web

podman exec caddy wget -qO- http://headscale:8080/health
curl -I https://headscale.yourdomain.com
```

---

## 12. Create Headscale user and register nodes

```bash
podman exec headscale headscale users create admin
podman exec headscale headscale users list
```

On a client:

```bash
tailscale up --login-server https://headscale.yourdomain.com
```

Approve on the server:

```bash
podman exec headscale headscale nodes register --user admin --key <nodekey>
podman exec headscale headscale nodes list
```

---

## 13. Inspect policy / group membership

```bash
podman exec headscale headscale policy get
podman exec headscale headscale policy get | grep -B1 '"admin@"'
```

Validate a policy file before applying (note: requires explicit path):

```bash
podman exec headscale headscale policy check --file /etc/headscale/policy.hujson
```

After editing the policy:

```bash
systemctl restart headscale.service
```

---

## 14. Logs

```bash
journalctl --no-pager -u headscale.service -f
journalctl --no-pager -u caddy.service -f

podman logs --tail=100 headscale
podman logs --tail=100 caddy
```

---

## 15. Auto-update

```bash
systemctl enable --now podman-auto-update.timer
systemctl list-timers --all | grep podman
podman auto-update --dry-run
```

---

## 16. Snapshots

Before upgrades:

```bash
btrfs subvolume snapshot -r /srv/appdata /srv/appdata-backup-$(date +%Y%m%d-%H%M)
```

Rollback:

```bash
mv /srv/appdata /srv/appdata-broken
btrfs subvolume snapshot /srv/appdata-backup-YYYYMMDD-HHMM /srv/appdata
systemctl restart headscale.service caddy.service
```

---

### Critical files to back up
- `/srv/appdata/headscale/config/config.yaml`
- `/srv/appdata/headscale/config/policy.hujson`
- `/srv/appdata/headscale/data/db.sqlite`
- `/srv/appdata/headscale/data/noise_private.key`
- `/srv/appdata/caddy/data/` (TLS certs)

## 17. Tag nodes and apply ACLs

### How the ACL flow works

A Headscale ACL rule evaluates:

1. **Who is connecting?**  
   The source node belongs to a user group, such as `group:admins` or `group:personal`.

2. **Which node is being accessed?**  
   The destination node has one or more tags, such as `tag:server` or `tag:media`.

3. **Does an ACL rule allow that source-to-destination combination?**  
   If a matching `accept` rule exists, traffic is allowed. Otherwise, traffic is denied.

![](/assets/headscale-setup_1.svg)

For example, this policy rule:

```json
{
  "action": "accept",
  "src": ["group:personal"],
  "dst": [
    "tag:server:22,80,443",
    "tag:media:8096",
    "tag:monitoring:3000"
  ]
}
```

means:

- A node owned by a member of `group:personal` may access:
  - `tag:server` on ports `22`, `80`, and `443`
  - `tag:media` on port `8096`
  - `tag:monitoring` on port `3000`
- Other ports and destinations remain blocked unless another rule allows them.

### Add a tag to a node

First list the nodes:

```bash
podman exec headscale headscale nodes list
```

Example:

```text
ID  Hostname    User     Tags
3   server-01   admin
```

Assign a tag:

```bash
podman exec headscale headscale nodes tag \
  --identifier 3 \
  --tags tag:server
```

Assign multiple tags:

```bash
podman exec headscale headscale nodes tag \
  --identifier 3 \
  --tags tag:server,tag:monitoring
```

Replace `3` with the actual node ID.

Verify the assignment:

```bash
podman exec headscale headscale nodes list
```

The tag must first be declared in the `tagOwners` section of `policy.hujson`:

```json
"tagOwners": {
  "tag:server": ["group:admins"],
  "tag:monitoring": ["group:admins"],
  "tag:media": ["group:admins"]
}
```

In this example, only members of `group:admins` may assign those tags.

### Apply or reload ACL rules

Edit the policy file on the host:

```bash
nano /srv/appdata/headscale/config/policy.hujson
```

Validate it before applying:

```bash
podman exec headscale headscale policy check \
  --file /etc/headscale/policy.hujson
```

If validation succeeds, restart Headscale:

```bash
systemctl restart headscale.service
```

Check that the service started successfully:

```bash
systemctl status --no-pager -l headscale.service
```

Confirm the active policy:

```bash
podman exec headscale headscale policy get
```

If your installed Headscale version provides a policy reload command, you can check its syntax with:

```bash
podman exec headscale headscale policy --help
```

Use a live reload only if that command is available. Otherwise, restarting the service is the reliable method.

### Confirm group membership

List Headscale users:

```bash
podman exec headscale headscale users list
```

For local users without an email address, Headscale represents the policy identity with a trailing `@`. For example:

```text
admin
```

is referenced in `policy.hujson` as:

```json
"admin@"
```

Check the active group entry:

```bash
podman exec headscale headscale policy get | grep -B1 -A1 '"admin@"'
```

### Confirm the complete policy and tags

```bash
podman exec headscale headscale policy get
podman exec headscale headscale nodes list
```

Inspect recent policy or startup errors:

```bash
journalctl --no-pager -u headscale.service -n 50
```

Remember: assigning a tag alone does not grant access. The tag must also appear in the destination side of an ACL rule that matches the source user's group.
