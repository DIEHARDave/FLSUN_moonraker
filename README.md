# FLSUN_moonraker

Replaces the 2023 Moonraker that FLSun ships on the **FLSun T1 Pro** with a current upstream release ([Moonraker v0.11.0](https://github.com/Arksine/moonraker/releases/tag/v0.11.0)), updated afterwards from Mainsail's or Fluidd's update manager like any other Moonraker.

Klipper and the stock screen are not touched.

## Why it takes a while

Current Moonraker needs Python 3.10 or newer. FLSun's image is Debian 10 with Python 3.7, and FLSun deleted the compiler, the C headers and most of dpkg's file lists from it. So the installer:

1. **Points apt at archive.debian.org.** Debian 10 has left the regular mirrors, so FLSun's apt sources return 404. Its list is kept as `/etc/apt/sources.list.flsun`.
2. **Reinstalls the compiler and the `-dev` packages.** They're still marked as installed, so they're reinstalled rather than installed.
3. **Builds Python 3.13** into `/usr/local` as `python3.13`, beside the system's Python 3.7. Klipper and FLSun's software keep using 3.7.
4. **Installs Moonraker from git** into `~/moonraker`, with a new `~/moonraker-env`. Some of its Python packages (Pillow among them) compile on the printer.
5. **Moves FLSun's Moonraker aside.** `~/moonraker`, `~/moonraker-env` and the database are kept as `~/moonraker.flsun`, `~/moonraker-env.flsun` and `~/printer_data/database.flsun`.

Moonraker components that plugins link into `~/moonraker/moonraker/components` (FLSUN_Updater, FLSUN_notify and FLSUN_Timelapse do) are linked into the new Moonraker too. On first start Moonraker converts FLSun's database to its newer format, so history, settings and update state carry over.

## Install

The printer must be idle. Building Python takes about an hour, and Moonraker is down only for the last minute or so.

SSH into the printer as `pi` (the default password is `1`), then:

```sh
sudo ntpdate -u -b time.google.com
curl -fsSL --cacert /etc/ssl/certs/ca-certificates.crt https://raw.githubusercontent.com/DIEHARDave/FLSUN_moonraker/main/prepare.sh | bash
cd ~
git clone https://github.com/DIEHARDave/FLSUN_moonraker.git
nohup ~/FLSUN_moonraker/install.sh > ~/printer_data/logs/flsun_moonraker.log 2>&1 &
tail -f ~/printer_data/logs/flsun_moonraker.log
```

The first two commands set the clock and repair certificates and git so that `git clone` works. `nohup` keeps the install going if the SSH session drops, and `tail` follows it (Ctrl+C stops following, not the install). The installer asks for `pi`'s password for `sudo` at the start unless it's already cached.

The installer can be run again at any time. Finished steps, such as the Python build, are skipped. `MOONRAKER_REF=<tag or branch>` before the command installs another Moonraker version.

If you use [FLSUN_Updater](https://github.com/DIEHARDave/FLSUN_Updater), update it first: older versions of its Moonraker component only work with FLSun's Moonraker.

## After installing

Moonraker shows up in the update manager (**Machine** page in Mainsail, **Settings → Software Updates** in Fluidd) and updates from there. FLSun's `moonraker.conf` sets `channel: dev` under `[update_manager]`, so it follows Moonraker's development branch; set `channel: stable` there to get releases only.

Klipper still shows as invalid in the update manager, as it did before: FLSun's Klipper isn't a git checkout.

## Uninstall

```sh
~/FLSUN_moonraker/uninstall.sh
rm -rf ~/FLSUN_moonraker
```

This puts FLSun's Moonraker, its venv and its database back. Anything Moonraker saved after the switch, such as print history and settings, is lost. Python 3.13, the compiler and the archive.debian.org apt sources stay; they don't affect FLSun's software.

## License

GPL-3.0. See [LICENSE](LICENSE).
