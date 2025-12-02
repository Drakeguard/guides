`/usr/local/sbin/ntfy-login-notify.sh`:

```sh
#!/usr/bin/env sh
#
# Failsafe ntfy login notification script for PAM

# ----- CONFIG -----
NTFY_URL=""
NTFY_TOPIC="logins"
NTFY_TOKEN="ntfy_xxxxxxxxxxxxxxxxx"
# -------------------

# If token or URL is missing, silently do nothing
[ -z "$NTFY_URL" ] && exit 0
[ -z "$NTFY_TOPIC" ] && exit 0
[ -z "$NTFY_TOKEN" ] && exit 0

# curl must exist, otherwise abort quietly
if ! command -v curl >/dev/null 2>&1; then
    exit 0
fi

# ----- SERVER INFO -----
SERVER_IP="$(hostname -I 2>/dev/null | awk 'NF{print $1; exit}')"
[ -z "$SERVER_IP" ] && SERVER_IP="unknown"

# ----- LOGIN INFO (from PAM if available) -----
USER_NAME="${PAM_USER:-$(id -un 2>/dev/null)}"
RHOST="${PAM_RHOST:-${SSH_CONNECTION%% *}}"
TTY="${PAM_TTY:-$(tty 2>/dev/null)}"
SERVICE="${PAM_SERVICE:-unknown}"

[ -z "$USER_NAME" ] && USER_NAME="unknown"
[ -z "$RHOST" ] && RHOST="local"
[ -z "$TTY" ] && TTY="unknown"

MESSAGE="User ${USER_NAME} logged in from ${RHOST} via ${SERVICE} on ${TTY} (server: ${SERVER_IP})"

# ----- SEND NOTIFICATION (non-blocking, short timeouts) -----
{
    curl -sS -X POST \
        --max-time 3 \
        --connect-timeout 2 \
        -H "Authorization: Bearer ${NTFY_TOKEN}" \
        -H "Title: Login on $(hostname) (${SERVER_IP})" \
        -H "Priority: high" \
        -H "Tags: login,server" \
        -d "${MESSAGE}" \
        "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1
} &

# Always succeed so PAM never fails because of notifications
exit 0
```

### Permissions

```bash
sudo chmod 700 /usr/local/sbin/ntfy-login-notify.sh
sudo chown root:root /usr/local/sbin/ntfy-login-notify.sh
```

---

## ✅ PAM config (login only, failsafe)

For SSH logins: `/etc/pam.d/sshd`:

```text
session [success=1 default=ignore] pam_exec.so seteuid type=open_session /usr/local/sbin/ntfy-login-notify.sh
```

For local console logins: `/etc/pam.d/login`:

```text
session [success=1 default=ignore] pam_exec.so seteuid type=open_session /usr/local/sbin/ntfy-login-notify.sh
```

* `type=open_session` → only on login, not logout
* `pam_exec.so` → runs the script
* Script always `exit 0`, so it **cannot** cause login failure
* only notify on remote logins (skip `RHOST=local`).
