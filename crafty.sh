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
pkg update -y || err "Package index update failed. Run 'pkg update' and try again."
pkg install -y openssh termux-services curl git python clang llvm rust cmake pkg-config libffi openssl argon2 python-psutil python-cryptography python-pillow openjdk-21 || err "Package installation failed."
# Reinstall OpenSSH so its current Termux service definition is present even when
# OpenSSH was installed before termux-services.
pkg reinstall -y openssh >/dev/null 2>&1 || true
echo '    OK: Packages installed'

python - <<'PY' || err 'Python 3.9+ is required.'
import sys
if sys.version_info < (3, 9):
    raise SystemExit(f"Python 3.9+ required; found {sys.version.split()[0]}")
PY

# termux-services normally initializes these after a shell restart. Do it here
# explicitly so the installer works in the same Termux session.
mkdir -p "$S" "$PREFIX/var/log" "$PREFIX/var/run" "$C/logs"
export SVDIR="$S" LOGDIR="$PREFIX/var/log"
if [[ -f "$PREFIX/etc/profile.d/start-services.sh" ]]; then
    # shellcheck disable=SC1091
    . "$PREFIX/etc/profile.d/start-services.sh" || true
fi
# The profile script may launch service-daemon asynchronously.
if ! pgrep -f "$PREFIX/bin/runsvdir" >/dev/null 2>&1; then
    service-daemon start >/dev/null 2>&1 || true
fi
sleep 2

# OpenSSH's package owns its service directory. Restore it if it is missing.
if [[ ! -d "$S/sshd" ]]; then
    pkg reinstall -y openssh >/dev/null 2>&1 || true
fi
if [[ -d "$S/sshd" ]]; then
    rm -f "$S/sshd/down"
    SVDIR="$S" sv up sshd >/dev/null 2>&1 || true
    if ! SVDIR="$S" sv status sshd 2>/dev/null | grep -q '^run:'; then
        echo '    WARNING: SSHD service exists but is not running; continuing with Crafty.'
    else
        echo '    OK: SSHD is running'
    fi
else
    echo '    WARNING: SSHD service definition is unavailable; continuing with Crafty.'
fi

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
export ARGON2_CFFI_USE_SYSTEM=1
export CMAKE_PREFIX_PATH="$PREFIX"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"

echo '    Using Termux system CMake/Argon2/LLVM to avoid pip building CMake from source.'
echo '    Native/Rust-backed packages may still take several minutes on Android.'
echo "    Live output is shown and saved to $C/pip-install.log"
if ! "$P" -m pip install --disable-pip-version-check --prefer-binary -r "$t/requirements.txt" 2>&1 | tee "$C/pip-install.log"; then
    echo '    ERROR: Python dependency installation failed.' >&2
    tail -n 60 "$C/pip-install.log" >&2 || true
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
mkdir -p "$S/crafty/log" "$C/logs" "$HOME/minecraft" "$(dirname "$BOOT")"
cat > "$S/crafty/run" <<EOF
#!$PREFIX/bin/sh
cd "$R" || exit 1
export PYTHONUNBUFFERED=1
exec "$P" main.py -d -i >> "$LOG" 2>&1
EOF
chmod 700 "$S/crafty/run"
rm -f "$S/crafty/down"
ln -sf "$PREFIX/share/termux-services/svlogger" "$S/crafty/log/run"
chmod 700 "$S/crafty/log/run" 2>/dev/null || true

# Make sure the supervisor is actually watching the service directory.
if ! pgrep -f "$PREFIX/bin/runsvdir" >/dev/null 2>&1; then
    service-daemon start >/dev/null 2>&1 || true
    sleep 2
fi
SVDIR="$S" sv up crafty >/dev/null 2>&1 || true

cat > "$BOOT" <<EOF
#!$PREFIX/bin/sh
export SVDIR="$S" LOGDIR="$PREFIX/var/log"
mkdir -p "$PREFIX/var/run" "$S"
if [[ -f "$PREFIX/etc/profile.d/start-services.sh" ]]; then
    . "$PREFIX/etc/profile.d/start-services.sh" || true
fi
if ! pgrep -f "$PREFIX/bin/runsvdir" >/dev/null 2>&1; then
    service-daemon start >/dev/null 2>&1 || true
fi
rm -f "$S/crafty/down"
SVDIR="$S" sv up crafty >/dev/null 2>&1 || true
SVDIR="$S" sv up sshd >/dev/null 2>&1 || true
EOF
chmod 700 "$BOOT"

printf '\n==> Verifying Crafty\n'
started=0
for i in {1..60}; do
    if SVDIR="$S" sv status crafty 2>/dev/null | grep -q '^run:'; then started=1; break; fi
    sleep 1
done
if (( ! started )); then
    echo '    ERROR: Crafty failed to start.' >&2
    echo "    Service directory: $S/crafty" >&2
    ls -la "$S/crafty" 2>&1 || true
    echo '    Service status:' >&2
    SVDIR="$S" sv status crafty 2>&1 || true
    echo '    Run script syntax:' >&2
    "$PREFIX/bin/sh" -n "$S/crafty/run" 2>&1 || true
    echo '    Crafty log:' >&2
    tail -n 80 "$LOG" 2>/dev/null || true
    echo '    Runit log:' >&2
    tail -n 80 "$PREFIX/var/log/sv/crafty/current" 2>/dev/null || true
    exit 1
fi
echo '    OK: Crafty service is running'

grep -Fqx "export SVDIR=\"$S\"" "$HOME/.bashrc" 2>/dev/null || echo "export SVDIR=\"$S\"" >> "$HOME/.bashrc"
grep -Fqx "export LOGDIR=\"$PREFIX/var/log\"" "$HOME/.bashrc" 2>/dev/null || echo "export LOGDIR=\"$PREFIX/var/log\"" >> "$HOME/.bashrc"

printf '\n==> Verifying HTTPS endpoint\n'
ready=0
for i in {1..60}; do
    if curl -ksf --connect-timeout 1 --max-time 2 https://127.0.0.1:8443/ >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
if (( ! ready )); then
    echo '    ERROR: Crafty HTTPS endpoint is not responding.' >&2
    tail -n 80 "$LOG" 2>/dev/null || true
    exit 1
fi
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
printf '========================================\n\nSSHD status:\n'; SVDIR="$S" sv status sshd 2>&1 || true
printf '\nCrafty status:\n'; SVDIR="$S" sv status crafty
printf '\nCrafty log: %s\nService log: %s\nCredentials: %s\n' "$LOG" "$PREFIX/var/log/sv/crafty/current" "$CREDS"
