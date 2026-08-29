#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

readonly HOME_C="${HOME}/crafty"
readonly REPO="${HOME_C}/crafty-4"
readonly PY="${REPO}/.venv/bin/python"
readonly SVDIR_C="${PREFIX}/var/service"
readonly CREDS="${REPO}/app/config/default-creds.txt"
readonly LOG="${HOME_C}/logs/crafty.log"
readonly BASHRC="${HOME}/.bashrc"
readonly BOOT="${HOME}/.termux/boot/start-crafty"
export SVDIR="$SVDIR_C" LOGDIR="${PREFIX}/var/log"

say(){ printf '\n==> %s\n' "$*"; }
ok(){ printf '    OK: %s\n' "$*"; }
die(){ printf '    ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "${PREFIX}/bin/pkg" ]] || die "This script must run inside Termux."

say "Installing required packages"
apt-get update -qq
apt-get install -y -qq openssh termux-services curl git python clang make openssl libffi rust cmake python-psutil python-cryptography python-pillow openjdk-21
ok "Packages installed"

say "Configuring services"
mkdir -p "$SVDIR_C" "${PREFIX}/var/log"
command -v service-daemon >/dev/null 2>&1 && service-daemon start >/dev/null 2>&1 || true
command -v sv-enable >/dev/null 2>&1 && sv-enable sshd >/dev/null 2>&1 || true
[[ -d "$SVDIR_C/sshd" ]] || die "SSHD service was not created."
sv up sshd >/dev/null 2>&1 || die "Failed to start SSHD."
ok "SSHD is running"

say "Installing Crafty"
mkdir -p "$HOME_C"
if [[ ! -d "$REPO/.git" ]]; then
    git clone --depth 1 https://gitlab.com/crafty-controller/crafty-4.git "$REPO"
elif git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
    git -C "$REPO" pull --ff-only --depth 1
fi
ok "Crafty source ready"

python - "$REPO/app/classes/helpers/helpers.py" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old='        for item in psutil.disk_partitions(all=False):\n'
new='''        try:\n            partitions = psutil.disk_partitions(all=False)\n        except PermissionError:\n            partitions = []\n        for item in partitions:\n'''
if old in s: p.write_text(s.replace(old,new,1))
elif 'partitions = psutil.disk_partitions(all=False)' not in s: raise SystemExit('Crafty compatibility patch target changed')
PY

say "Installing Python dependencies"
[[ -x "$PY" ]] || python -m venv --system-site-packages "$REPO/.venv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
grep -Ev '^(psutil|cryptography|pillow)==' "$REPO/requirements.txt" > "$tmp/requirements.txt"
printf 'cryptography==48.0.1\n' > "$tmp/constraints.txt"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}" "$PY" -m pip install --no-cache-dir -c "$tmp/constraints.txt" -r "$tmp/requirements.txt" >/dev/null
"$PY" -m pip install --no-cache-dir tzdata >/dev/null
rm -rf "$tmp"
trap - EXIT
ok "Python dependencies installed"

say "Configuring autostart"
mkdir -p "$SVDIR_C/crafty" "${HOME_C}/logs" "${HOME}/minecraft" "$(dirname "$BOOT")"
cat > "$SVDIR_C/crafty/run" <<EOF
#!${PREFIX}/bin/sh
cd ${REPO} || exit 1
export PYTHONUNBUFFERED=1
exec ${PY} main.py -d -i >> ${LOG} 2>&1
EOF
chmod 700 "$SVDIR_C/crafty/run"
cat > "$BOOT" <<EOF
#!${PREFIX}/bin/sh
export SVDIR=${SVDIR_C}
export LOGDIR=${PREFIX}/var/log
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
chmod 700 "$BOOT"
sv down crafty >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
sleep 2
if ! sv status crafty 2>/dev/null | grep -q '^run:'; then
    printf '    ERROR: Failed to start Crafty.\n'
    printf '    Last Crafty log lines:\n'
    tail -n 20 "$LOG" 2>/dev/null || printf '    No Crafty log was created.\n'
    exit 1
fi
ok "Crafty is running"

grep -Fqx "export SVDIR=\"$SVDIR_C\"" "$BASHRC" 2>/dev/null || printf '\nexport SVDIR="%s"\n' "$SVDIR_C" >> "$BASHRC"
grep -Fqx 'export LOGDIR="${PREFIX}/var/log"' "$BASHRC" 2>/dev/null || printf 'export LOGDIR="${PREFIX}/var/log"\n' >> "$BASHRC"

say "Verifying"
for _ in {1..15}; do curl -kfsS -o /dev/null https://127.0.0.1:8443/ && break; sleep 2; done
curl -kfsS -o /dev/null https://127.0.0.1:8443/ || die "Crafty HTTPS check failed. Log: $LOG"
ok "Crafty HTTPS endpoint is responding"

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$ip" ]] || ip="DEVICE_IP"
user="admin"; pass="Unavailable"
if [[ -f "$CREDS" ]]; then
    read -r user pass < <("$PY" - "$CREDS" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); print(c.get('username','admin'),c.get('password','Unavailable'))
PY
)
fi

printf '\n========================================\n  CRAFTY INSTALLATION COMPLETE\n========================================\n'
printf 'Dashboard : https://%s:8443\nUsername  : %s\nPassword  : %s\n' "$ip" "$user" "$pass"
printf '========================================\n\nSSHD status:\n'; sv status sshd
printf '\nCrafty status:\n'; sv status crafty
printf '\nCredentials: %s\n' "$CREDS"
printf 'Log: %s\n' "$LOG"
