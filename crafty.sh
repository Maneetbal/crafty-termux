#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

readonly CRAFTY_HOME="${HOME}/crafty"
readonly CRAFTY_REPO="${CRAFTY_HOME}/crafty-4"
readonly CRAFTY_VENV="${CRAFTY_REPO}/.venv"
readonly CRAFTY_CREDS="${CRAFTY_REPO}/app/config/default-creds.txt"
readonly SERVICE_DIR="${PREFIX:-}/var/service"
readonly CRAFTY_SERVICE="${SERVICE_DIR}/crafty"
readonly SSH_SERVICE="${SERVICE_DIR}/sshd"
readonly BOOT_SCRIPT="${HOME}/.termux/boot/start-crafty"
readonly BASHRC="${HOME}/.bashrc"
readonly LOGDIR="${PREFIX:-}/var/log"

TMP_DIR=""
export SVDIR="${SERVICE_DIR}" LOGDIR

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    OK: %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() { printf '    ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

require_termux() {
    [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/pkg" ]] || die "This script must run inside Termux."
}

install_packages() {
    say "Installing required Termux packages"
    pkg update -y
    pkg install -y openssh termux-services curl git python clang make openssl libffi rust cmake \
        python-psutil python-cryptography python-pillow openjdk-21
    ok "Termux packages are installed"
}

configure_sshd() {
    say "Configuring SSHD"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "OpenSSH/SSHD was not installed."
    mkdir -p "$SERVICE_DIR" "$LOGDIR"
    command -v service-daemon >/dev/null 2>&1 && service-daemon start >/dev/null 2>&1 || true
    command -v sv-enable >/dev/null 2>&1 && sv-enable sshd >/dev/null 2>&1 || true
    [[ -e "$SSH_SERVICE" ]] || die "Unable to create the Termux SSHD service."
    sv up sshd || die "Unable to start SSHD through termux-services."
    ok "SSHD service is enabled and running"
}

clone_or_update_crafty() {
    say "Installing the latest Crafty Controller source"
    mkdir -p "$CRAFTY_HOME"
    if [[ ! -d "$CRAFTY_REPO/.git" ]]; then
        git clone --depth 1 https://gitlab.com/crafty-controller/crafty-4.git "$CRAFTY_REPO"
    elif git -C "$CRAFTY_REPO" diff --quiet && git -C "$CRAFTY_REPO" diff --cached --quiet; then
        git -C "$CRAFTY_REPO" pull --ff-only --depth 1
    else
        warn "Local Crafty changes detected; leaving them untouched."
    fi
    ok "Crafty source is present at $CRAFTY_REPO"
}

patch_for_termux() {
    say "Applying Android compatibility patch"
    python - "$CRAFTY_REPO/app/classes/helpers/helpers.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "        for item in psutil.disk_partitions(all=False):\n"
new = """        try:
            partitions = psutil.disk_partitions(all=False)
        except PermissionError:
            partitions = []
        for item in partitions:
"""
if old in s:
    p.write_text(s.replace(old, new, 1), encoding="utf-8")
elif "partitions = psutil.disk_partitions(all=False)" not in s:
    raise SystemExit("Crafty helper layout changed; refusing to patch automatically")
PY
    ok "Android /proc permission compatibility is configured"
}

install_python_dependencies() {
    say "Installing Crafty Python dependencies"
    [[ -x "$CRAFTY_VENV/bin/python" ]] || python -m venv --system-site-packages "$CRAFTY_VENV"
    TMP_DIR="$(mktemp -d "$PREFIX/tmp/crafty-termux.XXXXXX")"
    grep -Ev '^(psutil|cryptography|pillow)==' "$CRAFTY_REPO/requirements.txt" > "$TMP_DIR/requirements.txt"
    printf 'cryptography==48.0.1\n' > "$TMP_DIR/constraints.txt"
    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}"
    "$CRAFTY_VENV/bin/python" -m pip install --no-cache-dir -c "$TMP_DIR/constraints.txt" -r "$TMP_DIR/requirements.txt"
    "$CRAFTY_VENV/bin/python" -m pip install --no-cache-dir tzdata
    ok "Crafty Python dependencies are installed"
}

configure_shell_environment() {
    say "Configuring Termux service environment"
    touch "$BASHRC"
    grep -Fqx "export SVDIR=\"$SERVICE_DIR\"" "$BASHRC" || printf '\nexport SVDIR="%s"\n' "$SERVICE_DIR" >> "$BASHRC"
    grep -Fqx "export LOGDIR=\"$LOGDIR\"" "$BASHRC" || printf 'export LOGDIR="%s"\n' "$LOGDIR" >> "$BASHRC"
    ok "SVDIR is configured persistently for sv commands"
}

configure_crafty_service() {
    say "Configuring Crafty autostart"
    mkdir -p "$CRAFTY_SERVICE" "$CRAFTY_HOME/logs" "$HOME/minecraft" "$(dirname "$BOOT_SCRIPT")"
    cat > "$CRAFTY_SERVICE/run" <<EOF
#!${PREFIX}/bin/sh
cd ${CRAFTY_REPO}
export TZ=UTC
exec ${CRAFTY_VENV}/bin/python main.py --daemon >> ${CRAFTY_HOME}/logs/crafty-service.log 2>&1
EOF
    chmod 700 "$CRAFTY_SERVICE/run"
    cat > "$BOOT_SCRIPT" <<EOF
#!${PREFIX}/bin/sh
export SVDIR=${SERVICE_DIR}
export LOGDIR=${LOGDIR}
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
    chmod 700 "$BOOT_SCRIPT"
    sv up crafty || die "Unable to start Crafty through termux-services."
    ok "Crafty service is enabled and running"
    ok "Termux:Boot hook installed at $BOOT_SCRIPT"
}

verify() {
    say "Verifying installation"
    [[ -x "$PREFIX/bin/sshd" ]] || die "SSHD executable is missing."
    [[ -x "$CRAFTY_VENV/bin/python" && -f "$CRAFTY_REPO/main.py" && -x "$CRAFTY_SERVICE/run" && -x "$BOOT_SCRIPT" ]] || die "Crafty installation is incomplete."
    for _ in {1..10}; do
        curl -kfsS -o /dev/null https://127.0.0.1:8443/ && break
        sleep 3
    done
    curl -kfsS -o /dev/null https://127.0.0.1:8443/ || die "Crafty HTTPS check failed."
    ok "Crafty HTTPS endpoint is responding"
}

show_success() {
    local device_ip username password
    device_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$device_ip" && "$device_ip" != "127.0.0.1" ]] || device_ip="DEVICE_IP"
    username="admin"
    password="Unavailable"
    if [[ -f "$CRAFTY_CREDS" ]]; then
        read -r username password < <("$CRAFTY_VENV/bin/python" - "$CRAFTY_CREDS" <<'PY'
import json, pathlib, sys
c = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(c.get("username", "admin"), c.get("password", "Unavailable"))
PY
)
    fi

    printf '\n========================================\n'
    printf '       CRAFTY INSTALLATION COMPLETE\n'
    printf '========================================\n'
    printf 'Dashboard : https://%s:8443\n' "$device_ip"
    printf 'Username  : %s\n' "$username"
    printf 'Password  : %s\n' "$password"
    printf '========================================\n\n'
    printf 'SSHD status:\n'
    sv status sshd
    printf '\nCrafty status:\n'
    sv status crafty
    printf '\nCredentials file: %s\n' "$CRAFTY_CREDS"
}

main() {
    require_termux
    install_packages
    configure_sshd
    clone_or_update_crafty
    patch_for_termux
    install_python_dependencies
    configure_shell_environment
    configure_crafty_service
    verify
    show_success
}

main "$@"
