#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail

readonly CRAFTY_HOME="${HOME}/crafty"
readonly CRAFTY_REPO="${CRAFTY_HOME}/crafty-4"
readonly CRAFTY_VENV="${CRAFTY_REPO}/.venv"
readonly CRAFTY_CREDS="${CRAFTY_REPO}/app/config/default-creds.txt"
readonly SERVICE_DIR="${PREFIX:-}/var/service"
readonly CRAFTY_SERVICE="${SERVICE_DIR}/crafty"
readonly SSH_SERVICE="${SERVICE_DIR}/sshd"
readonly BOOT_DIR="${HOME}/.termux/boot"
readonly BOOT_SCRIPT="${BOOT_DIR}/start-crafty"
readonly BASHRC="${HOME}/.bashrc"
readonly LOGDIR="${PREFIX:-}/var/log"
readonly CRAFTY_TAG="v4.10.8"

TMP_DIR=""
export SVDIR="${SERVICE_DIR}"
export LOGDIR

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
    pkg install -y openssh termux-services curl git python clang llvm make openssl libffi rust cmake pkg-config argon2 \
        python-psutil python-cryptography python-pillow openjdk-21
    ok "Termux packages are installed"
}

configure_sshd() {
    say "Configuring SSHD"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "OpenSSH/SSHD was not installed."
    mkdir -p "${SERVICE_DIR}" "${LOGDIR}"
    command -v service-daemon >/dev/null 2>&1 && service-daemon start >/dev/null 2>&1 || true
    command -v sv-enable >/dev/null 2>&1 && sv-enable sshd >/dev/null 2>&1 || true

    if [[ -e "${SSH_SERVICE}" ]]; then
        sv up sshd || die "Unable to start SSHD through termux-services."
        ok "SSHD service is enabled and running"
    else
        warn "The termux-services SSHD service was not created automatically."
        warn "Continuing; Crafty does not require SSHD to run."
    fi
}

clone_or_update_crafty() {
    say "Installing Crafty Controller ${CRAFTY_TAG}"
    mkdir -p "${CRAFTY_HOME}"
    if [[ ! -d "${CRAFTY_REPO}/.git" ]]; then
        git clone --depth 1 --branch "${CRAFTY_TAG}" https://gitlab.com/crafty-controller/crafty-4.git "${CRAFTY_REPO}"
    else
        git -C "${CRAFTY_REPO}" fetch --depth 1 origin tag "${CRAFTY_TAG}"
        git -C "${CRAFTY_REPO}" checkout --force "${CRAFTY_TAG}"
    fi
    ok "Crafty source is present at ${CRAFTY_REPO}"
}

patch_for_termux() {
    say "Applying Android compatibility patch"
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
elif "partitions = psutil.disk_partitions(all=False)" not in text:
    raise SystemExit("Crafty helper layout changed; refusing to patch automatically")
PY
    ok "Android /proc permission compatibility is configured"
}

install_python_dependencies() {
    say "Installing Crafty Python dependencies"
    [[ -x "${CRAFTY_VENV}/bin/python" ]] || python -m venv --system-site-packages "${CRAFTY_VENV}"

    TMP_DIR="$(mktemp -d "${PREFIX}/tmp/crafty-termux.XXXXXX")"
    grep -Ev '^(psutil|cryptography|pillow)==' "${CRAFTY_REPO}/requirements.txt" > "${TMP_DIR}/requirements.txt"
    printf 'cryptography==48.0.1\n' > "${TMP_DIR}/constraints.txt"

    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}"
    export ARGON2_CFFI_USE_SYSTEM=1
    export CMAKE_PREFIX_PATH="${PREFIX}"
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export PATH="${PREFIX}/bin:${PATH}"
    export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
    (( CARGO_BUILD_JOBS >= 1 && CARGO_BUILD_JOBS <= 4 )) || CARGO_BUILD_JOBS=4

    echo "    Installing native dependencies from Termux where available"
    echo "    Live pip output is shown below"
    "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir -c "${TMP_DIR}/constraints.txt" -r "${TMP_DIR}/requirements.txt"
    "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir tzdata
    ok "Crafty Python dependencies are installed"
}

configure_shell_environment() {
    say "Configuring Termux service environment"
    touch "${BASHRC}"
    grep -Fqx "export SVDIR=\"${SERVICE_DIR}\"" "${BASHRC}" || printf '\nexport SVDIR="%s"\n' "${SERVICE_DIR}" >> "${BASHRC}"
    grep -Fqx "export LOGDIR=\"${LOGDIR}\"" "${BASHRC}" || printf 'export LOGDIR="%s"\n' "${LOGDIR}" >> "${BASHRC}"
    ok "SVDIR is configured persistently for sv commands"
}

configure_crafty_service() {
    say "Configuring Crafty autostart"
    mkdir -p "${CRAFTY_SERVICE}" "${CRAFTY_HOME}/logs" "${HOME}/minecraft"
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
export SVDIR=${SERVICE_DIR}
export LOGDIR=${LOGDIR}
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
    chmod 700 "${BOOT_SCRIPT}"

    for _ in {1..5}; do
        sv up crafty >/dev/null 2>&1 && break
        sleep 2
    done
    sv status crafty >/dev/null 2>&1 || die "Unable to start Crafty through termux-services."
    ok "Crafty service is enabled and running"
    ok "Termux:Boot hook installed at ${BOOT_SCRIPT}"
}

verify() {
    say "Verifying installation"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "SSHD executable is missing."
    [[ -x "${CRAFTY_VENV}/bin/python" && -f "${CRAFTY_REPO}/main.py" ]] || die "Crafty installation is incomplete."
    [[ -x "${CRAFTY_SERVICE}/run" && -x "${BOOT_SCRIPT}" ]] || die "Crafty autostart files are missing."

    for _ in {1..10}; do
        curl -kfsS -o /dev/null https://127.0.0.1:8443/ && break
        sleep 3
    done
    curl -kfsS -o /dev/null https://127.0.0.1:8443/ || die "Crafty HTTPS check failed."
    ok "Crafty HTTPS endpoint is responding"
}

show_success() {
    local username password
    username="admin"
    password="Unavailable"
    if [[ -f "${CRAFTY_CREDS}" ]]; then
        read -r username password < <("${CRAFTY_VENV}/bin/python" - "${CRAFTY_CREDS}" <<'PY'
import json
import pathlib
import sys
c = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(c.get("username", "admin"), c.get("password", "Unavailable"))
PY
)
    fi

    printf '\n========================================\n'
    printf '       CRAFTY INSTALLATION COMPLETE\n'
    printf '========================================\n'
    printf 'Dashboard : https://localhost:8443\n'
    printf 'Username  : %s\n' "${username}"
    printf 'Password  : %s\n' "${password}"
    printf '========================================\n\n'
    printf 'SSHD status:\n'
    sv status sshd 2>/dev/null || true
    printf '\nCrafty status:\n'
    sv status crafty
    printf '\nCredentials file: %s\n' "${CRAFTY_CREDS}"
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
