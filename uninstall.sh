#!/bin/bash
# Puts FLSun's Moonraker, its venv and its database back from the *.flsun
# copies install.sh kept. Python 3.13 in /usr/local, the reinstalled
# compiler and the archive.debian.org apt list stay; they don't affect
# FLSun's software.

set -e

MR_DIR="${HOME}/moonraker"
MR_ENV="${HOME}/moonraker-env"
DATA_DIR="${HOME}/printer_data"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as the pi user, not root (sudo is used where needed)"
[ -d "${MR_DIR}.flsun" ] && [ -d "${MR_ENV}.flsun" ] \
    || die "${MR_DIR}.flsun or ${MR_ENV}.flsun is missing; nothing to restore"

msg "Stopping Moonraker"
sudo systemctl stop moonraker

msg "Restoring FLSun's Moonraker"
# Plugins linked in after the switch should still load.
for link in "${MR_DIR}/moonraker/components"/*; do
    [ -L "$link" ] || continue
    ln -sfn "$(readlink "$link")" "${MR_DIR}.flsun/moonraker/components/$(basename "$link")"
done
rm -rf "$MR_DIR" "$MR_ENV"
mv "${MR_DIR}.flsun" "$MR_DIR"
mv "${MR_ENV}.flsun" "$MR_ENV"

if [ -d "${DATA_DIR}/database.flsun" ]; then
    msg "Restoring FLSun's database (changes made since the switch are lost)"
    rm -rf "${DATA_DIR}/database"
    mv "${DATA_DIR}/database.flsun" "${DATA_DIR}/database"
fi

msg "Starting Moonraker"
sudo systemctl start moonraker

msg "Done. Delete ~/FLSUN_moonraker to finish."
