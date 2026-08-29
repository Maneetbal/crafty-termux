#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

C="$HOME/crafty"; R="$C/crafty-4"; P="$R/.venv/bin/python"
S="$PREFIX/var/service"; CREDS="$R/app/config/default-creds.txt"
LOG="$C/logs/crafty.log"; BOOT="$HOME/.termux/boot/start-crafty"
export SVDIR="$S" LOGDIR="$PREFIX/var/log"

err(){ echo "    ERROR: $*" >&2; exit 1; }
[[ -x "$PREFIX/bin/pkg" ]] || err "Run this script in Termux."

printf '\n==> Installing packages\n'
pkg update -y >/dev/null
pkg install -y openssh termux-services curl git python clang make openssl libffi rust cmake python-psutil python-cryptography python-pillow openjdk-21 >/dev/null
echo '    OK: Packages installed'

mkdir -p "$S" "$PREFIX/var/log"
command -v service-daemon >/dev/null 2>&1 && service-daemon start >/dev/null 2>&1 || true
sv-enable sshd >/dev/null 2>&1 || true
[[ -d "$S/sshd" ]] || err 'SSHD service was not created.'
sv up sshd >/dev/null 2>&1 || err 'Failed to start SSHD.'
echo '    OK: SSHD is running'

printf '\n==> Installing Crafty\n'
mkdir -p "$C"
[[ -d "$R/.git" ]] || git clone --depth 1 https://gitlab.com/crafty-controller/crafty-4.git "$R"
echo '    OK: Crafty source ready'

python - "$R/app/classes/helpers/helpers.py" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
a='        for item in psutil.disk_partitions(all=False):\n'
b='''        try:\n            partitions = psutil.disk_partitions(all=False)\n        except PermissionError:\n            partitions = []\n        for item in partitions:\n'''
if a in s: p.write_text(s.replace(a,b,1))
PY

printf '\n==> Installing Python dependencies\n'
[[ -x "$P" ]] || python -m venv --system-site-packages "$R/.venv"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
grep -Ev '^(psutil|cryptography|pillow)==' "$R/requirements.txt" > "$t/requirements.txt"
printf 'cryptography==48.0.1\n' > "$t/constraints.txt"
ANDROID_API_LEVEL=34 "$P" -m pip install --no-cache-dir -c "$t/constraints.txt" -r "$t/requirements.txt" >/dev/null
"$P" -m pip install --no-cache-dir tzdata >/dev/null
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
    if curl -kfsS --connect-timeout 1 --max-time 2 -o /dev/null https://127.0.0.1:8443/ 2>/dev/null; then ready=1; break; fi
    sleep 1
done
(( ready )) || { echo '    ERROR: Crafty HTTPS endpoint is not responding'; tail -n 20 "$LOG" 2>/dev/null || true; exit 1; }
echo '    OK: Crafty HTTPS endpoint is responding'

ip=$(hostname -I 2>/dev/null | awk '{print $1}'); [[ -n "$ip" ]] || ip=DEVICE_IP
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
