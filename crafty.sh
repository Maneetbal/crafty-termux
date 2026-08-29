#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

C="$HOME/crafty"; R="$C/crafty-4"; P="$R/.venv/bin/python"
S="$PREFIX/var/service"; CREDS="$R/app/config/default-creds.txt"
LOG="$C/logs/crafty.log"; BOOT="$HOME/.termux/boot/start-crafty"
CRAFTY_TAG="v4.10.8"
export SVDIR="$S" LOGDIR="$PREFIX/var/log" PIP_DISABLE_PIP_VERSION_CHECK=1

err(){ echo "    ERROR: $*" >&2; exit 1; }
[[ -x "$PREFIX/bin/pkg" ]] || err "Run this script in Termux."

printf '\n==> Installing packages\n'
apt-get update -qq || err "Package index update failed. Run 'pkg update' and try again."
apt-get install -y -qq openssh termux-services curl git python clang rust libffi openssl python-psutil python-cryptography python-pillow openjdk-21 || err "Package installation failed."
echo '    OK: Packages installed'

python - <<'PY' || exit 1
import sys
if sys.version_info < (3, 9):
    raise SystemExit(f"Python 3.9+ required; found {sys.version.split()[0]}")
PY

mkdir -p "$S" "$PREFIX/var/log" "$C/logs"
service-daemon start >/dev/null 2>&1 || true
sv-enable sshd >/dev/null 2>&1 || { sv up sshd >/dev/null 2>&1 || err 'Failed to enable/start SSHD.'; }
echo '    OK: SSHD is running'

printf '\n==> Installing Crafty %s\n' "$CRAFTY_TAG"
mkdir -p "$C"
if [[ ! -d "$R/.git" ]]; then
    git clone --depth 1 --branch "$CRAFTY_TAG" https://gitlab.com/crafty-controller/crafty-4.git "$R" || err "Failed to clone Crafty $CRAFTY_TAG."
else
    cd "$R"
    git fetch --depth 1 origin tag "$CRAFTY_TAG" || err "Failed to fetch Crafty $CRAFTY_TAG."
    git checkout --force "$CRAFTY_TAG" || err "Failed to checkout Crafty $CRAFTY_TAG."
fi
echo '    OK: Crafty source ready'

python - "$R/app/classes/helpers/helpers.py" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old='        for item in psutil.disk_partitions(all=False):'
if old in s:
    s=s.replace(old, '''        try:\n            partitions = psutil.disk_partitions(all=False)\n        except PermissionError:\n            partitions = []\n        for item in partitions:''', 1)
    p.write_text(s)
elif 'partitions = psutil.disk_partitions(all=False)' not in s:
    raise SystemExit('Crafty compatibility patch target changed; refusing unsafe patch')
PY

printf '\n==> Installing Python dependencies\n'
[[ -x "$P" ]] || python -m venv --system-site-packages "$R/.venv" || err 'Failed to create Python virtual environment.'
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
grep -Ev '^(psutil|cryptography|pillow)==' "$R/requirements.txt" > "$t/requirements.txt"
export PIP_NO_INPUT=1 CARGO_TERM_COLOR=never
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
(( CARGO_BUILD_JOBS >= 1 && CARGO_BUILD_JOBS <= 4 )) || CARGO_BUILD_JOBS=4

echo '    Native/Rust-backed packages may take several minutes on Android.'
echo "    Live output is shown and saved to $C/pip-install.log"
if ! ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}" "$P" -m pip install --disable-pip-version-check --prefer-binary -r "$t/requirements.txt" 2>&1 | tee "$C/pip-install.log"; then
    echo '    ERROR: Python dependency installation failed.' >&2
    tail -n 40 "$C/pip-install.log" >&2 || true
    exit 1
fi
if ! "$P" -m pip install --disable-pip-version-check tzdata 2>&1 | tee -a "$C/pip-install.log"; then
    echo '    ERROR: Failed to install tzdata.' >&2
    tail -n 20 "$C/pip-install.log" >&2 || true
    exit 1
fi
rm -rf "$t"; trap - EXIT
echo '    OK: Python dependencies installed'

printf '\n==> Configuring services\n'
mkdir -p "$S/crafty" "$S/crafty/log" "$C/logs" "$HOME/minecraft" "$(dirname "$BOOT")"
cat > "$S/crafty/run" <<EOF
#!$PREFIX/bin/sh
cd "$R" || exit 1
export PYTHONUNBUFFERED=1
exec "$P" main.py -d -i >> "$LOG" 2>&1
EOF
chmod 700 "$S/crafty/run"
ln -sf "$PREFIX/share/termux-services/svlogger" "$S/crafty/log/run" 2>/dev/null || true
sv-enable crafty >/dev/null 2>&1 || { sv up crafty >/dev/null 2>&1 || err 'Failed to enable/start Crafty.'; }

cat > "$BOOT" <<EOF
#!$PREFIX/bin/sh
export SVDIR="$S" LOGDIR="$PREFIX/var/log"
mkdir -p "$PREFIX/var/run"
service-daemon start >/dev/null 2>&1 || true
sv-enable sshd >/dev/null 2>&1 || true
sv-enable crafty >/dev/null 2>&1 || true
EOF
chmod 700 "$BOOT"

printf '\n==> Verifying Crafty\n'
started=0
for i in {1..60}; do
    if sv status crafty 2>/dev/null | grep -q '^run:'; then started=1; break; fi
    sleep 1
done
(( started )) || { echo '    ERROR: Crafty failed to start' >&2; tail -n 40 "$LOG" 2>/dev/null || true; echo "    Service log: $PREFIX/var/log/sv/crafty/current" >&2; exit 1; }
echo '    OK: Crafty service is running'

grep -Fqx "export SVDIR=\"$S\"" "$HOME/.bashrc" 2>/dev/null || echo "export SVDIR=\"$S\"" >> "$HOME/.bashrc"
grep -Fqx "export LOGDIR=\"$PREFIX/var/log\"" "$HOME/.bashrc" 2>/dev/null || echo "export LOGDIR=\"$PREFIX/var/log\"" >> "$HOME/.bashrc"

printf '\n==> Verifying HTTPS endpoint\n'
ready=0
for i in {1..60}; do
    if curl -ksf --connect-timeout 1 --max-time 2 https://127.0.0.1:8443/ >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
(( ready )) || { echo '    ERROR: Crafty HTTPS endpoint is not responding' >&2; tail -n 40 "$LOG" 2>/dev/null || true; exit 1; }
echo '    OK: Crafty HTTPS endpoint is responding'

ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
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
printf 'Crafty     : %s\nDashboard   : https://%s:8443\nUsername    : %s\nPassword    : %s\n' "$CRAFTY_TAG" "$ip" "$user" "$pass"
printf '========================================\n\nSSHD status:\n'; sv status sshd
printf '\nCrafty status:\n'; sv status crafty
printf '\nCrafty log: %s\nService log: %s\nCredentials: %s\n' "$LOG" "$PREFIX/var/log/sv/crafty/current" "$CREDS"
