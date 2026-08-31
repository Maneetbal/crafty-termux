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
readonly JAVA_HOME_TERMUX="${PREFIX:-}/lib/jvm/java-25-openjdk"

TMP_DIR=""
export SVDIR="${SERVICE_DIR}"
export LOGDIR

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    OK: %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() { printf '    ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf -- "${TMP_DIR}"; }
trap cleanup EXIT

require_termux() {
    [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/pkg" ]] || die "This script must run inside Termux."
    [[ "$(uname -o 2>/dev/null || true)" == "Android" ]] || warn "Host is not identified as Android; continuing because PREFIX is valid."
}

install_packages() {
    say "Installing required Termux packages"
    pkg update -y
    pkg install -y openssh termux-services curl git python clang make openssl libffi rust cmake \
        python-psutil python-cryptography python-pillow openjdk-25
    ok "Termux packages are installed"
}

configure_java() {
    say "Configuring Java 25"
    [[ -x "${JAVA_HOME_TERMUX}/bin/java" ]] || die "OpenJDK 25 is not installed correctly."
    export JAVA_HOME="${JAVA_HOME_TERMUX}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    hash -r 2>/dev/null || true
    local java_version
    java_version="$(java -version 2>&1 | awk -F'\"' '/version/ {print $2; exit}')"
    [[ "${java_version}" == 25.* ]] || die "Java 25 is required for current Velocity builds; found ${java_version:-unknown}."
    ok "Java 25 is active (${java_version})"
}

configure_sshd() {
    say "Configuring SSHD"
    [[ -x "${PREFIX}/bin/sshd" ]] || die "OpenSSH/SSHD was not installed."
    mkdir -p "${SERVICE_DIR}" "${LOGDIR}"
    command -v service-daemon >/dev/null 2>&1 && service-daemon start >/dev/null 2>&1 || true
    command -v sv-enable >/dev/null 2>&1 && sv-enable sshd >/dev/null 2>&1 || true
    if [[ -e "${SSH_SERVICE}" ]]; then
        sv up sshd || die "Unable to start SSHD through termux-services."
        ok "SSHD service is running"
    else
        warn "SSHD service was not created automatically; continuing."
    fi
}

clone_or_update_crafty() {
    say "Installing Crafty Controller ${CRAFTY_TAG}"
    mkdir -p "${CRAFTY_HOME}"
    if [[ ! -d "${CRAFTY_REPO}/.git" ]]; then
        git clone --depth 1 --branch "${CRAFTY_TAG}" https://gitlab.com/crafty-controller/crafty-4.git "${CRAFTY_REPO}"
    else
        if git -C "${CRAFTY_REPO}" diff --quiet && git -C "${CRAFTY_REPO}" diff --cached --quiet; then
            git -C "${CRAFTY_REPO}" fetch --depth 1 origin "refs/tags/${CRAFTY_TAG}:refs/tags/${CRAFTY_TAG}"
            git -C "${CRAFTY_REPO}" checkout --force "${CRAFTY_TAG}"
        else
            warn "Local Crafty changes detected; leaving them untouched."
        fi
    fi
    ok "Crafty source is present at ${CRAFTY_REPO}"
}

create_venv() {
    [[ -x "${CRAFTY_VENV}/bin/python" ]] || python -m venv --system-site-packages "${CRAFTY_VENV}"
}

patch_for_termux() {
    say "Applying Android compatibility patches"
    "${CRAFTY_VENV}/bin/python" - "${CRAFTY_REPO}/app/classes/helpers/helpers.py" "${CRAFTY_REPO}/app/classes/remote_stats/stats.py" <<'PY'
from pathlib import Path
import sys

helpers = Path(sys.argv[1])
stats = Path(sys.argv[2])

text = helpers.read_text(encoding="utf-8")
old = "        for item in psutil.disk_partitions(all=False):\n"
new = """        try:
            partitions = psutil.disk_partitions(all=False)
        except (PermissionError, FileNotFoundError, OSError):
            partitions = []
        for item in partitions:
"""
if old in text:
    text = text.replace(old, new, 1)
elif "partitions = psutil.disk_partitions(all=False)" not in text:
    raise SystemExit("Crafty disk-partition code changed; refusing to patch automatically")
helpers.write_text(text, encoding="utf-8")

text = stats.read_text(encoding="utf-8")
old = """        try:
            cpu_freq = psutil.cpu_freq()
        except (NotImplementedError, AttributeError, FileNotFoundError):
            cpu_freq = None
        if cpu_freq is None:
            cpu_freq = psutil._common.scpufreq(current=-1, min=-1, max=-1)
"""
new = """        try:
            cpu_freq = psutil.cpu_freq()
        except (NotImplementedError, AttributeError, FileNotFoundError, PermissionError, OSError):
            cpu_freq = (-1.0, -1.0, -1.0)
"""
if old in text:
    text = text.replace(old, new, 1)
elif "cpu_freq = (-1.0, -1.0, -1.0)" not in text:
    raise SystemExit("Crafty CPU-frequency code changed; refusing to patch automatically")
stats.write_text(text, encoding="utf-8")
PY
    "${CRAFTY_VENV}/bin/python" -m py_compile \
        "${CRAFTY_REPO}/app/classes/helpers/helpers.py" \
        "${CRAFTY_REPO}/app/classes/remote_stats/stats.py"
    ok "Android disk and CPU-frequency compatibility patches are configured"
}

install_python_dependencies() {
    say "Installing Crafty Python dependencies"
    TMP_DIR="$(mktemp -d "${PREFIX}/tmp/crafty-termux.XXXXXX")"
    grep -Ev '^(psutil|cryptography|pillow)==' "${CRAFTY_REPO}/requirements.txt" > "${TMP_DIR}/requirements.txt"
    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}"
    export ARGON2_CFFI_USE_SYSTEM=1
    export CMAKE_PREFIX_PATH="${PREFIX}"
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export PATH="${PREFIX}/bin:${JAVA_HOME_TERMUX}/bin:${PATH}"
    export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
    (( CARGO_BUILD_JOBS >= 1 && CARGO_BUILD_JOBS <= 4 )) || CARGO_BUILD_JOBS=4

    echo "    Native builds may take time; live pip output follows"
    if ! "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir \
        -r "${TMP_DIR}/requirements.txt" 2>&1 | tee "${CRAFTY_HOME}/pip-install.log"; then
        die "Python dependency installation failed. See ${CRAFTY_HOME}/pip-install.log"
    fi
    "${CRAFTY_VENV}/bin/python" -m pip install --no-cache-dir tzdata
    "${CRAFTY_VENV}/bin/python" -m pip uninstall -y cryptography >/dev/null 2>&1 || true
    "${CRAFTY_VENV}/bin/python" -c 'import cryptography; from cryptography.hazmat.bindings import _rust; print(f"    Cryptography {cryptography.__version__}: {cryptography.__file__}")'
    ok "Crafty Python dependencies are installed"
}

configure_shell_environment() {
    say "Configuring Termux service environment"
    touch "${BASHRC}"
    grep -Fqx "export SVDIR=\"${SERVICE_DIR}\"" "${BASHRC}" || printf '\nexport SVDIR="%s"\n' "${SERVICE_DIR}" >> "${BASHRC}"
    grep -Fqx "export LOGDIR=\"${LOGDIR}\"" "${BASHRC}" || printf 'export LOGDIR="%s"\n' "${LOGDIR}" >> "${BASHRC}"
    grep -Fqx "export JAVA_HOME=\"${JAVA_HOME_TERMUX}\"" "${BASHRC}" || printf 'export JAVA_HOME="%s"\n' "${JAVA_HOME_TERMUX}" >> "${BASHRC}"
    grep -Fqx 'export PATH="$JAVA_HOME/bin:$PATH"' "${BASHRC}" || printf 'export PATH="$JAVA_HOME/bin:$PATH"\n' >> "${BASHRC}"
    export JAVA_HOME="${JAVA_HOME_TERMUX}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    ok "SVDIR, LOGDIR, and Java 25 are configured persistently"
}

configure_crafty_service() {
    say "Configuring Crafty autostart"
    mkdir -p "${CRAFTY_SERVICE}" "${CRAFTY_HOME}/logs" "${HOME}/minecraft"
    cat > "${CRAFTY_SERVICE}/run" <<EOF
#!${PREFIX}/bin/sh
cd ${CRAFTY_REPO}
export TZ=UTC
export JAVA_HOME=${JAVA_HOME_TERMUX}
export PATH="\$JAVA_HOME/bin:\$PATH"
exec ${CRAFTY_VENV}/bin/python main.py --daemon >> ${CRAFTY_HOME}/logs/crafty-service.log 2>&1
EOF
    chmod 700 "${CRAFTY_SERVICE}/run"

    mkdir -p "${BOOT_DIR}"
    cat > "${BOOT_SCRIPT}" <<EOF
#!${PREFIX}/bin/sh
export SVDIR=${SERVICE_DIR}
export LOGDIR=${LOGDIR}
export JAVA_HOME=${JAVA_HOME_TERMUX}
export PATH="\$JAVA_HOME/bin:\$PATH"
sv up sshd >/dev/null 2>&1 || true
sv up crafty >/dev/null 2>&1 || true
EOF
    chmod 700 "${BOOT_SCRIPT}"

    for _ in {1..10}; do
        if sv up crafty >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    sv status crafty >/dev/null 2>&1 || die "Unable to start Crafty through termux-services."
    ok "Crafty service is enabled and running"
    ok "Termux:Boot hook installed at ${BOOT_SCRIPT}"
}

wait_for_crafty() {
    say "Waiting for Crafty initialization"
    for _ in {1..90}; do
        if grep -q "Crafty has fully started and is now ready for use!" "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null; then
            ok "Crafty is fully started"
            return
        fi
        if grep -q "Server Init Complete: Listening For Connections!" "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null; then
            ok "Crafty web server is initialized"
            return
        fi
        if ! sv status crafty 2>/dev/null | grep -q '^run:'; then
            echo "    ERROR: Crafty stopped while starting." >&2
            tail -n 100 "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    echo "    ERROR: Crafty did not finish starting." >&2
    tail -n 120 "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null || true
    exit 1
}

verify_host_stats() {
    say "Verifying HostStats collection"
    [[ -f "${CRAFTY_REPO}/app/config/db/crafty.sqlite" ]] || die "Crafty database was not created."

    for _ in {1..90}; do
        local rows
        rows="$(${CRAFTY_VENV}/bin/python - <<'PY'
import sqlite3
import os
p=os.path.expanduser("~/crafty/crafty-4/app/config/db/crafty.sqlite")
try:
    c=sqlite3.connect(p).cursor()
    print(c.execute("SELECT COUNT(*) FROM host_stats").fetchone()[0])
except Exception:
    print(0)
PY
)"
        if [[ "${rows}" =~ ^[0-9]+$ ]] && (( rows > 0 )); then
            ok "HostStats collection is working (${rows} row(s))"
            return
        fi
        sleep 1
    done

    echo "    ERROR: HostStats collection did not produce a row." >&2
    grep -n -A18 -B3 "Exception in thread tasks_starter\|PermissionError\|record_stats\|cpu_freq" \
        "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null | tail -120 || true
    exit 1
}

verify_https() {
    say "Verifying HTTPS endpoint"
    for _ in {1..20}; do
        if curl -kfsS --connect-timeout 2 --max-time 5 -o /dev/null https://127.0.0.1:8443/; then
            ok "Crafty HTTPS endpoint is responding"
            return
        fi
        sleep 2
    done
    echo "    ERROR: Crafty HTTPS endpoint is not responding." >&2
    tail -n 120 "${CRAFTY_HOME}/logs/crafty-service.log" 2>/dev/null || true
    exit 1
}

verify_java() {
    say "Verifying Java runtime"
    local version
    version="$("${JAVA_HOME_TERMUX}/bin/java" -version 2>&1 | awk -F'\"' '/version/ {print $2; exit}')"
    [[ "${version}" == 25.* ]] || die "Java 25 verification failed (found ${version:-unknown})."
    ok "Java 25 is available for Crafty-managed Minecraft/Velocity servers"
}

show_success() {
    local username="admin"
    local password="Unavailable"
    if [[ -f "${CRAFTY_CREDS}" ]]; then
        read -r username password < <("${CRAFTY_VENV}/bin/python" - "${CRAFTY_CREDS}" <<'PY'
import json
import pathlib
import sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(c.get("username","admin"), c.get("password","Unavailable"))
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
    printf '\nJava:\n'
    "${JAVA_HOME_TERMUX}/bin/java" -version 2>&1 | head -n 1
    printf '\nCredentials file: %s\n' "${CRAFTY_CREDS}"
    printf 'Dependency log : %s\n' "${CRAFTY_HOME}/pip-install.log"
}

main() {
    require_termux
    install_packages
    configure_java
    configure_sshd
    clone_or_update_crafty
    create_venv
    install_python_dependencies
    patch_for_termux
    configure_shell_environment
    configure_crafty_service
    wait_for_crafty
    verify_host_stats
    verify_https
    verify_java
    show_success
}

main "$@"
