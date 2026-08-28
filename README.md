# crafty-termux

`crafty-termux` installs and runs the official [Crafty Controller](https://craftycontrol.com/) on Android through Termux. It configures Crafty and Termux's SSH server as user-level services and adds a Termux:Boot hook for startup after Android boot.

This project adapts Crafty for Termux. Crafty itself is not a fork: the installer clones the upstream Crafty repository and applies one small Android compatibility patch for restricted `/proc` access. Termux-native packages are used where Android cannot use the normal Linux wheels.

## Requirements

- Android ARM64 device (other architectures may work but are not tested)
- Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or the official Termux GitHub releases
- Termux:Boot from the same source, opened once after installation
- Network access and approximately 1.5 GB free space for build dependencies
- Android battery-optimization exemption for Termux if Android stops long-running services

The installer does not require root. In Termux, the SSH account commonly appears as `root` even though it is an unprivileged Android app user.

## Installation

Download and run the installer inside Termux:

```sh
curl -O https://raw.githubusercontent.com/Maneetbal/crafty-termux/main/crafty.sh
chmod +x crafty.sh
./crafty.sh
```

The script is intended to be safe to rerun. It avoids replacing an existing SSH configuration and leaves local Crafty source changes untouched.

## What the installer does

1. Installs or updates Termux packages, including OpenSSH, Python, build tools, Java 21, and Termux services.
2. Starts SSHD through the Termux service supervisor without rewriting an existing `sshd_config`.
3. Clones the latest Crafty Controller source into `~/crafty/crafty-4`.
4. Creates a Python virtual environment using Termux-native system packages.
5. Applies the minimal Android compatibility patch required by Crafty's disk-mount detection.
6. Creates and starts the `crafty` service.
7. Creates `~/.termux/boot/start-crafty` to start SSHD and Crafty after Termux:Boot launches.
8. Verifies the service and Crafty's HTTPS endpoint.

## Accessing Crafty

Open:

```text
https://DEVICE_IP:8443
```

The first-run username is `admin`. The generated username and password are printed at the end of `crafty.sh` and saved in:

```sh
cat ~/crafty/crafty-4/app/config/default-creds.txt
```

Change the password immediately after logging in. Crafty uses a self-signed certificate by default, so the browser will show a certificate warning on first access.

## Service commands

```sh
sv status sshd
sv status crafty
sv up sshd
sv down sshd
sv up crafty
sv down crafty
sv restart crafty
```

Crafty logs are stored in `~/crafty/logs/crafty-service.log`; Crafty's own application logs are under `~/crafty/crafty-4/app/logs`.

## SSHD

The installer installs OpenSSH if needed and uses the existing Termux SSH service. The usual Termux SSH port is `8022`:

```sh
ssh -p 8022 USER@DEVICE_IP
```

Existing SSH keys and configuration are preserved. The installer starts the Termux service supervisor immediately when needed, so a fresh install does not require manually restarting the shell. If the service still needs manual recovery, run:

```sh
sv-enable sshd
sv up sshd
```

## Minecraft server

Java 21 is installed so Crafty can manage modern Minecraft Java servers. The installer creates `~/minecraft`, but it does not accept Mojang's EULA or download a server jar automatically. Add a server through Crafty's web panel and accept the EULA yourself.

## Updating Crafty

Stop Crafty, update the source and dependencies, then restart it:

```sh
sv down crafty
cd ~/crafty/crafty-4
git pull --ff-only
./.venv/bin/python -m pip install --no-cache-dir -r requirements.txt
sv up crafty
```

If an upstream update changes the helper code, rerun `crafty.sh` to reapply the Termux compatibility patch. Always back up `~/crafty/crafty-4/app/config` and your Minecraft worlds before updating.

## Uninstalling

To stop and remove the services and boot hook while keeping Crafty data:

```sh
sv down crafty || true
sv down sshd || true
rm -rf "$PREFIX/var/service/crafty"
rm -f ~/.termux/boot/start-crafty
```

To remove the Crafty installation and its data as well, first back up anything you need, then remove `~/crafty` and any Minecraft server directories you created.

## Troubleshooting

### Crafty does not start

```sh
sv status crafty
tail -n 100 ~/crafty/logs/crafty-service.log
```

Make sure Termux has not been battery-restricted and that Termux:Boot has been opened once. Android may stop background processes unless Termux is excluded from battery optimization.

### SSH connection refused

```sh
sv status sshd
sv restart sshd
sshd -T | grep -E '^(port|listenaddress) '
```

Confirm the device IP address and use port `8022` unless you intentionally changed the SSH configuration.

### Installation is slow

ARM64 packages such as Pillow, orjson, and other Rust-backed dependencies may compile locally. This can take several minutes on a tablet and does not necessarily indicate a network failure.

### Report a problem

Open an issue at [github.com/Maneetbal/crafty-termux/issues](https://github.com/Maneetbal/crafty-termux/issues) and include the Termux version, Android version, device architecture, the failing command, and relevant non-sensitive log output. Never post your Crafty password or SSH credentials.

