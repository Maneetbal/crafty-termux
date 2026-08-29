#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

C="$HOME/crafty"; R="$C/crafty-4"; P="$R/.venv/bin/python"
S="$PREFIX/var/service"; CREDS="$R/app/config/default-creds.txt"
LOG="$C/logs/crafty.log"; BOOT="$HOME/.termux/boot/start-crafty"
export SVDIR="$S" LOGDIR="$PREFIX/var/log" PIP_DISABLE_PIP_VERSION_CHECK=1

err(){ echo "    ERROR: $*" >&2; exit 1; }
[[ -x "$PREFIX/bin/pkg" ]] || err "Run this script in Termux."

printf '\n==> Installing packages\n'
if ! { apt-get update -qq && apt-get install -y -qq openssh termux-services curl git python clang rust libffi openssl python-psutil python-cryptography python-pillow openjdk-21; } >/dev/null 2>&1; then
    err "Package installation failed."
fi
echo '    OK: Packages installed'

mkdir -p "$S" "$PREFIX/var/log"
service-daemon start >/dev/null 2>&1 || true
sv-enable sshd >/dev/null 2>&1 || true
[[ -d "$S/sshd" ]] || err 'SSHD service was not created.'
sv up sshd >/dev/null 2>&1 || err 'Failed to start SSHD.'
echo '    OK: SSHD is running'

printf '\n==> Installing Crafty\n'
mkdir -p "$C"
if [[ ! -d "$R/.git" ]]; then
    git clone --depth 1 https://gitlab.com/crafty-controller/crafty-4.git "$R" >/dev/null 2>&1 || err 'Failed to clone Crafty.'
fi
echo '    OK: Crafty source ready'

python - "$R/app/classes/helpers/helpers.py" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
a='        for item in psutil.disk_partitions(all=False):\n'
b='''        try:\n            partitions = psutil.disk_partitions(all=False)\n        except PermissionError:\n            partitions = []\n        for item in partitions:\n'''
if a in s: p.write_text(s.replace(a,b,1))
elif 'partitions = psutil.disk_partitions(all=False)' not in s: raise SystemExit('Crafty compatibility patch target changed')
PY

printf '\n==> Installing Python dependencies\n'
[[ -x "$P" ]] || python -m venv --system-site-packages "$R/.venv"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
grep -Ev '^(psutil|cryptography|pillow)==' "$R/requirements.txt" > "$t/requirements.txt"
if ! ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}" "$P" -m pip install --disable-pip-version-check --no-cache-dir --prefer-binary -r "$t/requirements.txt" >"$C/pip-install.log" 2>&1; then
    echo '    ERROR: Python dependency installation failed.' >&2
    tail -n 30 "$C/pip-install.log" >&2
    exit 1
fi
"$P" -m pip install --disable-pip-version-check --no-cache-dir tzdata >>"$C/pip-install.log" 2>&1 || {
    echo '    ERROR: Failed to install tzdata.' >&2
    tail -n 20 "$C/pip-install.log" >&2
    exit 1
}
rm -rf "$t"; trap - EXIT
echo '    OK: Python dependencies installed'

printf '\n==> Configuring autostart\n'
mkdir -p "$S/crafty" "$C/logs" "$HOME/minecraft" "$(dirname "$BOOT")"
cat > "$S/crafty/run" <<EOF
#!$PREFIX/bin/sh
cd $R || exit 1
export PYTHONUNBUFFERED=1
exec $P main.py -d -i >> $LOG 2>&1
EOF
chmod 700 "$S/crafty/run"
cat > "$BOOT" <<EOF
#!$PREFIX/bin/sh
export SVDIR=$S LOGDIR=$PREFIX/var/log
service-daemon start >/dev/null 2>&1 || true
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
chmod 700 "$BOOT"

sv up crafty >/dev/null 2>&1 || true
for i in {1..30}; do
    sv status crafty 2>/dev/null | grep -q '^run:' && break
    sleep 1
done
sv status crafty 2>/dev/null | grep -q '^run:' || { echo '    ERROR: Crafty failed to start'; tail -n 20 "$LOG" 2>/dev/null || true; exit 1; }
echo '    OK: Crafty is running'

grep -Fqx "export SVDIR=\"$S\"" "$HOME/.bashrc" 2>/dev/null || echo "export SVDIR=\"$S\"" >> "$HOME/.bashrc"
grep -Fqx "export LOGDIR=\"$PREFIX/var/log\"" "$HOME/.bashrc" 2>/dev/null || echo "export LOGDIR=\"$PREFIX/var/log\"" >> "$HOME/.bashrc"

printf '\n==> Verifying\n'
ready=0
for i in {1..30}; do
    if curl -ksf --connect-timeout 1 --max-time 2 https://127.0.0.1:8443/ >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
(( ready )) || { echo '    ERROR: Crafty HTTPS endpoint is not responding'; tail -n 20 "$LOG" 2>/dev/null || true; exit 1; }
echo '    OK: Crafty HTTPS endpoint is responding'

ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n "$ip" ]] || ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[[ -n "$ip" ]] || ip="127.0.0.1"
user=admin; pass=Unavailable
if [[ -f "$CREDS" ]]; then
    read -r user pass < <("$P" - "$CREDS" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get('username','admin'),x.get('password','Unavailable'))
PY
)
fi

printf '\n========================================\n  CRAFTY INSTALLATION COMPLETE\n========================================\n'
printf 'Dashboard : https://%s:8443\nUsername  : %s\nPassword  : %s\n' "$ip" "$user" "$pass"
printf '========================================\n\nSSHD status:\n'; sv status sshd
printf '\nCrafty status:\n'; sv status crafty
printf '\nCredentials: %s\n' "$CREDS"
