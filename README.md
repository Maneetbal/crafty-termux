# crafty-termux

`crafty-termux` installs and runs the official Crafty Controller on Android through Termux. It configures Crafty and Termux's SSH server as user-level services and adds a Termux:Boot hook for startup after Android boot.

This project adapts Crafty for Termux. Crafty itself is not a fork: the installer checks out a tested Crafty release and applies one small Android compatibility patch for restricted `/proc` access. Termux-native packages are used where Android cannot use normal Linux wheels.

## Requirements

- Android ARM64 device. Other architectures may work but are not tested.
- Termux from F-Droid or the official Termux GitHub releases.
- Termux:Boot from the same source, opened once after installation if you want boot startup.
- Network access and approximately 1.5 GB free space for build dependencies.
- Battery-optimization exemption for Termux if Android stops long-running services.
- Current Termux packages with Python 3.9+.

The installer does not require root. Termux processes run as the app's unprivileged Android user.

## Installation

For a fresh Termux installation, install only `curl` first and let the script handle the rest:

```sh
pkg update -y
pkg install -y curl
curl -O https://raw.githubusercontent.com/Maneetbal/crafty-termux/main/crafty.sh
chmod +x crafty.sh
./crafty.sh
```

The installer is designed to be rerunnable. It pins Crafty to the tested release configured in `crafty.sh` so an upstream change cannot silently break a fresh install.

## What the installer does

1. Installs or updates the required Termux packages, including OpenSSH, Termux services, build tools, Rust, and OpenJDK 25.
2. Verifies that the active Java runtime is Java 25. This prevents modern Velocity builds using class-file version 69 from being launched with Java 21.
3. Starts and enables SSHD through the normal Termux service supervisor without replacing an existing SSH configuration.
4. Checks out the pinned Crafty Controller release.
5. Creates Crafty's Python virtual environment.
6. Applies the Android `/proc` compatibility patch needed by Crafty's disk detection.
7. Installs Python dependencies and allows native/Rust-backed packages to build on ARM64 when wheels are unavailable.
8. Uses the Termux-compatible `cryptography` package instead of allowing pip to replace it with an incompatible Android binary.
9. Uses Termux's system CMake, Argon2, LLVM, and pkg-config to avoid the CMake bootstrap failure encountered with `argon2-cffi-bindings`.
10. Creates, enables, and starts the Crafty runit service with Java 25 explicitly configured.
11. Creates `~/.termux/boot/start-crafty` with the same Java 25 environment for optional boot startup.
12. Verifies Crafty's service, Python cryptography import, and HTTPS endpoint before reporting success.

## Accessing Crafty

On the Android device itself, open:

```text
https://localhost:8443
```

From another device on the same LAN, replace `localhost` with the Android device's LAN IP, for example:

```text
https://192.168.1.92:8443
```

Crafty normally uses a self-signed certificate, so the browser may show a certificate warning on first access.

The generated username and password are printed at the end of the installer and stored in:

```sh
cat ~/crafty/crafty-4/app/config/default-creds.txt
```

Change the password after logging in.

## Service commands

```sh
sv status sshd
sv status crafty
sv-enable sshd
sv-enable crafty
sv up sshd
sv down sshd
sv up crafty
sv down crafty
sv restart crafty
```

`termux-services` uses runit and supervises enabled services.

Crafty's runit service log is:

```sh
$PREFIX/var/log/sv/crafty/current
```

Crafty's application log is:

```sh
~/crafty/logs/crafty-service.log
```

The dependency-install log is:

```sh
~/crafty/pip-install.log
```

## Java / Velocity

This installer uses **OpenJDK 25**. Current Velocity builds can require Java 25 and therefore cannot run on a Java 21 runtime.

Verify the active runtime with:

```sh
java -version
echo "$JAVA_HOME"
```

The expected runtime is Java 25, normally located at:

```text
$PREFIX/lib/jvm/java-25-openjdk
```

Crafty's runit service also exports this Java 25 environment explicitly, so it does not depend on the Java version selected by an interactive shell.

### `UnsupportedClassVersionError`

For an error similar to:

```text
class file version 69.0
this version of the Java Runtime only recognizes class file versions up to 65.0
```

Java 25 is installed but Java 21 is being selected. Check:

```sh
java -version
cat "$PREFIX/var/service/crafty/run"
```

The service file should contain:

```sh
export JAVA_HOME=$PREFIX/lib/jvm/java-25-openjdk
export PATH="$JAVA_HOME/bin:$PATH"
```

You can also force Java 25 for a manual launch:

```sh
$PREFIX/lib/jvm/java-25-openjdk/bin/java -jar velocity.jar
```

## Python / cryptography compatibility

Termux provides Android-compatible Python packages for several native dependencies. Crafty-termux deliberately avoids letting pip shadow the Termux `cryptography` build because an incompatible wheel can fail with an error such as:

```text
ImportError: dlopen failed: cannot locate symbol "PyBaseObject_Type"
```

Verify the installed venv copy with:

```sh
~/crafty/crafty-4/.venv/bin/python -c 'import cryptography; print(cryptography.__version__, cryptography.__file__)'
```

## Native dependency builds

On ARM64, some Python packages do not have a compatible Android wheel and may build locally. Packages such as `nh3`, `orjson`, `rpds-py`, `PyYAML`, `tornado`, or other Rust/C extensions can therefore take time to compile.

The installer keeps the output visible so a native build does not look frozen.

For the Argon2 dependency, the installer uses Termux's native CMake/Argon2/LLVM toolchain and sets:

```sh
ARGON2_CFFI_USE_SYSTEM=1
```

This avoids the failed pip CMake bootstrap that can otherwise end with `cmake` wheel build errors or exit status 11.

## SSHD

The installer uses Termux's normal OpenSSH service. The usual SSH port is `8022`:

```sh
ssh -p 8022 USER@DEVICE_IP
```

Existing SSH keys and configuration are preserved.

## Minecraft servers

Java 25 is available for modern Minecraft Java servers and Velocity. The installer creates `~/minecraft`, but it does not download server jars or accept Mojang's EULA automatically. Add servers through Crafty's web panel and accept the EULA yourself.

## Crafty updates

The installer intentionally pins a tested Crafty release. This protects fresh installations from unexpected upstream changes.

To reinstall the pinned release and reapply the Termux compatibility changes:

```sh
./crafty.sh
```

Back up your Crafty configuration and Minecraft data before updating:

```sh
cp -a ~/crafty/crafty-4/app/config ~/crafty-config-backup
cp -a ~/minecraft ~/minecraft-backup
```

To intentionally test a newer Crafty release, change `CRAFTY_TAG` in `crafty.sh` and test it on a backup first.

## Uninstalling

To stop and remove the services and boot hook while keeping Crafty data:

```sh
sv down crafty || true
sv down sshd || true
rm -rf "$PREFIX/var/service/crafty"
rm -f ~/.termux/boot/start-crafty
```

To remove Crafty itself, delete `~/crafty` after backing up any server data you need.

## Troubleshooting

### Crafty does not start

```sh
sv status crafty
tail -n 100 ~/crafty/logs/crafty-service.log
tail -n 100 "$PREFIX/var/log/sv/crafty/current"
```

Make sure Termux has not been battery-restricted. Android may terminate background processes even when the service configuration is correct.

### Crafty stays down after a stop

Crafty may wait for a Minecraft/Velocity child process to exit before completing shutdown. Do not manually start the service `run` script while runit is already supervising it, because that can create a duplicate Crafty agent.

Use:

```sh
sv status crafty
sv down crafty
sleep 10
sv status crafty
```

Then inspect running Java processes if a child server remains:

```sh
ps -ef | grep '[j]ava'
```

### Velocity uses Java 21

Check the exact Java executable of the running Velocity process:

```sh
PID=$(pgrep -f 'velocity.jar' | head -1)
readlink /proc/$PID/exe
```

For this installer it should resolve to:

```text
$PREFIX/lib/jvm/java-25-openjdk/bin/java
```

Also inspect the Crafty service environment:

```sh
cat "$PREFIX/var/service/crafty/run"
```

### Crafty HTTPS check fails during installation

The installer retries the HTTPS endpoint while Crafty finishes starting. If it still fails, inspect:

```sh
sv status crafty
tail -n 100 ~/crafty/logs/crafty-service.log
```

### `cryptography` has a `dlopen` or `PyBaseObject_Type` error

Verify the venv package:

```sh
~/crafty/crafty-4/.venv/bin/python -c 'import cryptography; print(cryptography.__version__, cryptography.__file__)'
```

Then rerun the installer to restore the tested dependency layout:

```sh
./crafty.sh
```

### Installation appears frozen during pip

Native extensions may be compiling. The installer intentionally shows build output. The full dependency log is available at:

```sh
~/crafty/pip-install.log
```

### `cmake` or `argon2-cffi-bindings` fails to build

Update Termux packages and rerun the installer:

```sh
pkg update
pkg upgrade
./crafty.sh
```

The installer installs the Termux native CMake/Argon2/LLVM toolchain specifically to avoid the pip CMake bootstrap failure.

### Report a problem

Open an issue and include your Termux version, Android version, CPU architecture, the failing command, and relevant non-sensitive logs. Never post your Crafty password, SSH credentials, API keys, or other secrets.
