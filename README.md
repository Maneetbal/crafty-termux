# crafty-termux

`crafty-termux` installs and runs the official Crafty Controller on Android through Termux. It configures Crafty and Termux's SSH server as user-level services and adds a Termux:Boot hook for startup after Android boot.

This project adapts Crafty for Termux. Crafty itself is not a fork: the installer checks out a tested Crafty release and applies one small Android compatibility patch for restricted `/proc` access. Termux-native packages are used where Android cannot use normal Linux wheels.

## Requirements

- Android ARM64 device (other architectures may work but are not tested)
- Termux from F-Droid or the official Termux GitHub releases
- Termux:Boot from the same source, opened once after installation if you want boot startup
- Network access and approximately 1.5 GB free space for build dependencies
- Battery-optimization exemption for Termux if Android stops long-running services
- Python 3.9+ supplied by current Termux packages

The installer does not require root. Termux processes run as the app's unprivileged Android user.

## Installation

Download and run the installer inside Termux:

```sh
curl -O https://raw.githubusercontent.com/Maneetbal/crafty-termux/main/crafty.sh
chmod +x crafty.sh
./crafty.sh
```

The installer is designed to be rerunnable. It pins the Crafty source to the tested release configured in `crafty.sh`, so a future upstream change cannot silently break a fresh install.

## What the installer does

1. Installs or updates Termux packages, including OpenSSH, Python, build tools, Rust, Java 21, and Termux services.
2. Checks that the Termux Python version meets Crafty's minimum requirement.
3. Starts and enables SSHD through the Termux service supervisor without rewriting an existing SSH configuration.
4. Clones or updates the Crafty source to the tested release.
5. Creates a Python virtual environment using Termux-native system packages.
6. Applies the minimal Android compatibility patch required by Crafty's disk-mount detection.
7. Installs Python dependencies with live output; Rust/native builds are allowed to take several minutes.
8. Creates, enables, and starts the `crafty` runit service.
9. Creates `~/.termux/boot/start-crafty` for optional boot startup.
10. Verifies both the service and Crafty's HTTPS endpoint.

## Accessing Crafty

Open:

```text
https://DEVICE_IP:8443
```

The generated username and password are printed at the end of the installer and stored in:

```sh
cat ~/crafty/crafty-4/app/config/default-creds.txt
```

Change the password immediately after logging in. Crafty normally uses a self-signed certificate, so the browser may show a certificate warning on first access.

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

`termux-services` uses runit and automatically supervises enabled services. Its service logs are under `$PREFIX/var/log/sv/<service>/current`. citeturn0search0

Crafty's installer log is:

```sh
~/crafty/pip-install.log
```

The Crafty service/application log is:

```sh
~/crafty/logs/crafty.log
```

## SSHD

The installer installs OpenSSH if needed and uses the existing Termux SSH service. The usual Termux SSH port is `8022`:

```sh
ssh -p 8022 USER@DEVICE_IP
```

Existing SSH keys and configuration are preserved. `sv-enable sshd` makes the service persistent under the Termux service supervisor. citeturn0search1

## Minecraft server

Java 21 is installed so Crafty can manage modern Minecraft Java servers. The installer creates `~/minecraft`, but it does not accept Mojang's EULA or download a server jar automatically. Add a server through Crafty's web panel and accept the EULA yourself.

## Updating Crafty

The installer intentionally pins the tested Crafty release. Do **not** use an unrestricted `git pull` if you want to retain that compatibility guarantee.

To reinstall the tested release and reapply the Termux compatibility patch:

```sh
./crafty.sh
```

Before updating, back up:

```sh
~/crafty/crafty-4/app/config
~/minecraft
```

If you intentionally test a newer Crafty release, change `CRAFTY_TAG` in `crafty.sh`, test it on a backup first, and verify the Android compatibility patch still applies.

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
tail -n 100 ~/crafty/logs/crafty.log
tail -n 100 "$PREFIX/var/log/sv/crafty/current"
```

Make sure Termux has not been battery-restricted. Android can terminate background processes, and Termux's own documentation notes that daemonized processes can be more vulnerable to Android process killing. citeturn0search11

### SSH connection refused

```sh
sv status sshd
sv restart sshd
sshd -T | grep -E '^(port|listenaddress) '
```

Confirm the device IP address and use port `8022` unless you intentionally changed the SSH configuration.

### Installation is slow

ARM64 packages such as `nh3`, Pillow, or other native/Rust-backed dependencies may compile locally. The installer now streams pip output and saves it to `~/crafty/pip-install.log`, so a long build should no longer look completely frozen.

### Dependency installation fails

Inspect the end of the log:

```sh
tail -n 100 ~/crafty/pip-install.log
```

Then retry the installer after confirming that Termux packages are current:

```sh
pkg update
pkg upgrade
./crafty.sh
```

### Report a problem

Open an issue in the repository and include the Termux version, Android version, device architecture, the failing command, and relevant non-sensitive log output. Never post your Crafty password or SSH credentials.
