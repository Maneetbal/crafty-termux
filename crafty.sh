#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail

readonly CRAFTY_HOME="${HOME}/crafty"
readonly CRAFTY_REPO="${CRAFTY_HOME}/crafty-4"
readonly CRAFTY_VENV="${CRAFTY_REPO}/.venv"
readonly CRAFTY_CREDS="${CRAFTY_REPO}/app/config/default-creds.txt"
readonly MC_HOME="${HOME}/minecraft"
readonly SERVICE_DIR="${PREFIX:-}/var/service"
readonly CRAFTY_SERVICE="${SERVICE_DIR}/crafty"
readonly SSH_SERVICE="${SERVICE_DIR}/sshd"
readonly BOOT_DIR="${HOME}/.termux/boot"
readonly BOOT_SCRIPT="${BOOT_DIR}/start-crafty"

TMP_DIR=""

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    OK: %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() { printf '    ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}
trap cleanup EXIT

require_termux() {
    [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/pkg" ]] || \
        die "This script must run inside Termux."
    [[ "$(uname -o 2>/dev/null || true)" == "Android" ]] || \
        warn "The host does not identify as Android; continuing because PREFIX is valid."
}

install_packages() {
    say "Installing required Termux packages"
    pkg update -y
    pkg install -y \
        openssh termux-services curl git python clang make openssl libffi rust cmake \
        python-psutil python-cryptography python-pillow openjdk-21
    ok "Termux packages are installed"
}

configure_sshd() {
    say "Configuring SSHD"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "OpenSSH/SSHD was not installed."

    mkdir -p "${SERVICE_DIR}"
    if command -v sv-enable >/dev/null 2>&1; then
        sv-enable sshd >/dev/null 2>&1 || true
    fi

    if [[ ! -e "${SSH_SERVICE}" ]]; then
        warn "The termux-services SSHD service was not created automatically."
        warn "Run: sv-enable sshd"
    else
        sv up sshd || die "Unable to start SSHD through termux-services."
        ok "SSHD service is enabled and running"
    fi

    if [[ -f "${PREFIX}/etc/ssh/sshd_config" ]]; then
        ok "Existing SSHD configuration preserved"
    else
        warn "No sshd_config was found; Termux defaults will be used."
    fi
}

clone_or_update_crafty() {
    say "Installing the latest Crafty Controller source"
    mkdir -p "${CRAFTY_HOME}"
    if [[ ! -d "${CRAFTY_REPO}/.git" ]]; then
        git clone --depth 1 https://gitlab.com/crafty-controller/crafty-4.git "${CRAFTY_REPO}"
    else
        git -C "${CRAFTY_REPO}" fetch --depth 1 origin
        if git -C "${CRAFTY_REPO}" diff --quiet && git -C "${CRAFTY_REPO}" diff --cached --quiet; then
            git -C "${CRAFTY_REPO}" pull --ff-only --depth 1
        else
            warn "Local Crafty changes detected; leaving them untouched."
        fi
    fi
    ok "Crafty source is present at ${CRAFTY_REPO}"
}

patch_for_termux() {
    say "Applying the minimal Android compatibility patch"
    python - "${CRAFTY_REPO}/app/classes/helpers/helpers.py" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "        for item in psutil.disk_partitions(all=False):\n"
new = """        try:
            partitions = psutil.disk_partitions(all=False)
        except PermissionError:
            partitions = []
        for item in partitions:
"""
if old in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
elif "partitions = psutil.disk_partitions(all=False)" in text:
    pass
else:
    raise SystemExit("Crafty helper layout changed; refusing to patch automatically")
PY
    ok "Android /proc permission compatibility is configured"
}

install_python_dependencies() {
    say "Installing Crafty Python dependencies"
    if [[ ! -x "${CRAFTY_VENV}/bin/python" ]]; then
        python -m venv --system-site-packages "${CRAFTY_VENV}"
    fi

    TMP_DIR="$(mktemp -d "${PREFIX}/tmp/crafty-termux.XXXXXX")"
    grep -Ev '^(psutil|cryptography|pillow)==' "${CRAFTY_REPO}/requirements.txt" \
        > "${TMP_DIR}/requirements.termux.txt"
    printf 'cryptography==48.0.1\n' > "${TMP_DIR}/constraints.txt"

    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}"
    "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir \
        -c "${TMP_DIR}/constraints.txt" -r "${TMP_DIR}/requirements.termux.txt"
    "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir tzdata
    ok "Crafty Python dependencies are installed"
}

configure_crafty_service() {
    say "Configuring Crafty autostart"
    mkdir -p "${CRAFTY_SERVICE}" "${CRAFTY_HOME}/logs" "${MC_HOME}"
    cat > "${CRAFTY_SERVICE}/run" <<EOF
#!${PREFIX}/bin/sh
cd ${CRAFTY_REPO}
export TZ=UTC
exec ${CRAFTY_VENV}/bin/python main.py --daemon >> ${CRAFTY_HOME}/logs/crafty-service.log 2>&1
EOF
    chmod 700 "${CRAFTY_SERVICE}/run"

    mkdir -p "${BOOT_DIR}"
    cat > "${BOOT_SCRIPT}" <<EOF
#!${PREFIX}/bin/sh
# Starts Crafty and SSHD when Termux:Boot launches this user session.
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
    chmod 700 "${BOOT_SCRIPT}"

    local attempt
    for attempt in 1 2 3 4 5; do
        if sv up crafty >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    sv status crafty >/dev/null 2>&1 || die "Unable to start Crafty through termux-services."
    ok "Crafty service is enabled and running"
    ok "Termux:Boot hook installed at ${BOOT_SCRIPT}"
}

verify() {
    say "Verifying installation"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "SSHD executable is missing."
    [[ -x "${CRAFTY_VENV}/bin/python" ]] || die "Crafty virtual environment is missing."
    [[ -f "${CRAFTY_REPO}/main.py" ]] || die "Crafty main.py is missing."
    [[ -x "${CRAFTY_SERVICE}/run" ]] || die "Crafty service file is missing."
    [[ -x "${BOOT_SCRIPT}" ]] || die "Termux:Boot hook is missing."

    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if curl -kfsS -o /dev/null https://127.0.0.1:8443/; then
            break
        fi
        sleep 3
    done
    sv status crafty || die "Crafty service is not running."
    curl -kfsS -o /dev/null https://127.0.0.1:8443/ || die "Crafty HTTPS check failed."
    ok "Crafty HTTPS endpoint is responding"
    ok "Crafty installation completed"
    local device_ip
    device_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -z "${device_ip}" || "${device_ip}" == "127.0.0.1" ]]; then
        device_ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' || true)"
    fi
    [[ -n "${device_ip}" ]] || device_ip="DEVICE_IP"
    printf '\nCrafty directory: %s\n' "${CRAFTY_REPO}"
    printf 'Dashboard: https://%s:8443\n' "${device_ip}"
    printf 'Credentials file: %s\n' "${CRAFTY_CREDS}"
    if [[ -f "${CRAFTY_CREDS}" ]]; then
        "${CRAFTY_VENV}/bin/python" - "${CRAFTY_CREDS}" <<'PY'
import json
import pathlib
import sys

credentials = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(f"Username: {credentials['username']}")
print(f"Password: {credentials['password']}")
PY
    else
        warn "Crafty credentials file was not generated yet."
    fi
    printf 'Service status: sv status crafty\n'
}

main() {
    require_termux
    install_packages
    configure_sshd
    clone_or_update_crafty
    patch_for_termux
    install_python_dependencies
    configure_crafty_service
    verify
}

main "$@"

