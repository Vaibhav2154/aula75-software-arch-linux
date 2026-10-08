# AULA F75 on Arch Linux

This repository sets up the official AULA F75 configuration application on
Arch Linux. The vendor application is a Windows program, so the setup runs it
inside Bottles with Wine while retaining access to the keyboard's USB HID
interface.

Once installed, you can change key mappings, profiles, RGB lighting, and
macros from the **AULA F75** application.

## What is in this repository

| File | Purpose |
| --- | --- |
| `setup-arch.sh` | Complete setup script for Arch Linux. |
| `AULA F75 Setup v2.0 20240509.exe` | Official AULA F75 Windows configuration installer. |
| `aula-hidfix.c` | Compatibility shim that lets the Windows application accept the keyboard's HID replies on Linux. |
| `70-aula-f75.rules` | udev rule that permits the logged-in user to access the keyboard HID device. |
| `setup.sh` | Older generic/Fedora-oriented setup script; do not use this on Arch. |

## Requirements

- Arch Linux (or an Arch-based distribution using `pacman`)
- An internet connection for Flathub, Bottles, and the Wine runner
- A user account with `sudo` access
- The AULA F75 connected by its **USB cable** while configuring it

The setup script installs the needed Arch packages itself: `flatpak`, `curl`,
`tar`, `xz`, `gcc`, `imagemagick`, `desktop-file-utils`, and `usbutils`.

## Install

From this directory, run:

```sh
./setup-arch.sh
```

The script will:

1. Install the required Arch packages.
2. Add Flathub and install Bottles.
3. Install a Wine 11.12 runner.
4. Add the AULA USB/HID udev rule.
5. Create an `AULA-F75` Bottles bottle.
6. Install the AULA F75 software.
7. Build and enable the HID compatibility shim.
8. Create an **AULA F75** application-menu launcher.

It is safe to run the script again; completed parts are skipped where
possible.

## Launching the configurator

After setup, open **AULA F75** from your application menu, or run:

```sh
flatpak run --command=bottles-cli com.usebottles.bottles run -b AULA-F75 -p "AULA F75"
```

Connect the keyboard by cable before opening the configurator. Bluetooth and
2.4 GHz wireless are fine for typing, but the vendor configuration channel is
normally exposed on the wired USB interface.

## Troubleshooting

- **The application says to connect a device:** reconnect the keyboard using
  its USB cable, then run `./setup-arch.sh` again to ensure the udev rule and
  HID shim are installed.
- **The application does not start:** run the terminal launch command above
  to see any Bottles error output, then re-run the setup script.
- **A new Bottle runner breaks detection:** in Bottles, ensure the `AULA-F75`
  bottle still uses `wine-11.12-amd64`. This runner is required for the HID
  collection layout used by the keyboard.

## License

The scripts and source in this repository are licensed under the MIT License.
The AULA installer is third-party vendor software.
