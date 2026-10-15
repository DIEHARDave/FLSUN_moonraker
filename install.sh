#!/bin/bash
# Replaces FLSun's 2023 Moonraker on the T1 Pro with an upstream release.
# Run as the pi user from the cloned repo: ~/FLSUN_moonraker/install.sh
#
# FLSun's image ships Python 3.7 (Moonraker now needs 3.10 or newer) and
# has deleted the compiler, the headers and most of dpkg's file lists, so
# this:
#   1. points apt at archive.debian.org (buster has left the mirrors),
#   2. reinstalls the compiler and the -dev packages,
#   3. builds Python into /usr/local (python3.13, beside the system 3.7),
#   4. installs Moonraker from git into ~/moonraker with its own venv,
#   5. keeps FLSun's ~/moonraker, ~/moonraker-env and database as *.flsun
#      so uninstall.sh can put them back.
# Klipper is not touched. The Python build takes about an hour.
#
# Safe to re-run: finished steps are skipped. MOONRAKER_REF=<tag or
# branch> installs another Moonraker version.

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_VERSION="3.13.16"
PY_SHA256="f4b1bfb3c79b5bb11b8d228a12504163b4c0dab4d679828d8f5f26b6cb6ab35d"
PY_BIN="/usr/local/bin/python${PY_VERSION%.*}"
MOONRAKER_REPO="https://github.com/Arksine/moonraker.git"
MOONRAKER_REF="${MOONRAKER_REF:-v0.11.0}"
MR_DIR="${HOME}/moonraker"
MR_ENV="${HOME}/moonraker-env"
DATA_DIR="${HOME}/printer_data"
BUILD_DIR="${HOME}/.cache/flsun_moonraker"
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

# Compiler and linker; FLSun deleted their files but left them marked
# installed, so they are reinstalled rather than installed.
TOOLCHAIN="binutils binutils-arm-linux-gnueabihf libbinutils cpp-8 gcc-8
    g++-8 gcc g++ cpp libgcc-8-dev libstdc++-8-dev libc6-dev libc-dev-bin
    linux-libc-dev libisl19 libmpc3 libmpfr6 libgmp10 libcc1-0 libgomp1
    libatomic1 libasan5 libubsan1 make pkg-config"
# Headers for Python's modules and for Moonraker's compiled packages
# (Pillow, libnacl, lmdb).
DEV_PACKAGES="libssl-dev libffi-dev zlib1g-dev libsqlite3-dev libbz2-dev
    liblzma-dev libreadline-dev libncurses-dev uuid-dev libgdbm-dev
    libjpeg62-turbo-dev libjpeg-dev libopenjp2-7-dev libfreetype6-dev
    libsodium-dev liblmdb-dev"
# Runtime libraries the -dev packages need newer point releases of.
RUNTIME_PACKAGES="libc6 libc-bin libssl1.1 libtinfo6 libncurses6
    libncursesw6 libuuid1"
# Shipped by FLSun with unmet dependencies; they block every apt install.
BROKEN_PACKAGES="librtmp-dev libvorbis-dev"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as the pi user, not root (sudo is used where needed)"
[ -d "${DATA_DIR}/config" ] || die "${DATA_DIR}/config not found"

# For unattended runs: SUDO_ASKPASS=<script that prints pi's password>
# makes every sudo here, and in prepare.sh, ask it instead of the terminal.
if [ -n "$SUDO_ASKPASS" ]; then
    sudo() { command sudo -A "$@"; }
    export -f sudo
fi

print_state() {
    curl -s --max-time 5 "http://127.0.0.1:7125/printer/objects/query?print_stats=state" \
        | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' \
        2> /dev/null || echo unknown
}
case "$(print_state)" in
    printing|paused) die "a print is running; run this after it finishes" ;;
esac

# Clock, certificates and git https support, shared with the other FLSun
# plugins; see prepare.sh.
"${REPO_DIR}/prepare.sh"

# ---------------------------------------------------------------- apt
if ! grep -qs archive.debian.org /etc/apt/sources.list; then
    msg "Pointing apt at archive.debian.org"
    [ -f /etc/apt/sources.list.flsun ] || sudo cp /etc/apt/sources.list /etc/apt/sources.list.flsun
    sudo install -m 644 "${REPO_DIR}/system/sources.list" /etc/apt/sources.list
fi
sudo install -m 644 "${REPO_DIR}/system/99flsun-archive" /etc/apt/apt.conf.d/99flsun-archive

compiler_works() {
    local t
    t=$(mktemp -d)
    printf '#include <stdio.h>\n#include <openssl/ssl.h>\n#include <zlib.h>\nint main(void){puts("ok");return 0;}\n' > "${t}/t.c"
    gcc -o "${t}/t" "${t}/t.c" -lssl -lz > /dev/null 2>&1 && "${t}/t" > /dev/null 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q --no-install-recommends \
        -o Dpkg::Options::=--force-confold "$@" 2>&1 \
        | { grep -v 'files list file for package' || true; }
    return "${PIPESTATUS[0]}"
}

# apt 1.8 sends the + in version numbers as %2b, which archive.debian.org's
# CDN answers with 404 for some files (as does a literal +; %2B always
# works). Download what apt would fetch with curl into its cache first, so
# apt only installs.
apt_prefetch() {
    local url file
    sudo apt-get -qq --print-uris --no-install-recommends install "$@" \
        | while read -r url file _; do
            url="${url//\'/}"
            [ -s "/var/cache/apt/archives/${file}" ] && continue
            url="${url//%2b/%2B}"
            url="${url//+/%2B}"
            sudo curl -fsSL --retry 3 -o "/var/cache/apt/archives/${file}" "$url" \
                || { echo "could not download $url" >&2; return 1; }
        done
}

if ! compiler_works; then
    msg "Reinstalling the compiler and headers (FLSun removed them)"
    sudo apt-get update -q
    # FLSun's image is already broken: two -dev packages it shipped are
    # missing dependencies, which stops apt from installing anything. Their
    # headers are gone anyway, so they're removed. The -dev packages also
    # need the last Debian 10 point releases of the libraries FLSun froze
    # older (libc6, libssl1.1, ncurses, libuuid1); apt upgrades those here.
    remove=""
    for pkg in $BROKEN_PACKAGES; do
        dpkg -s "$pkg" > /dev/null 2>&1 && remove="$remove ${pkg}-"
    done
    # shellcheck disable=SC2086
    apt_prefetch $RUNTIME_PACKAGES $TOOLCHAIN $DEV_PACKAGES $remove \
        && apt_get install $RUNTIME_PACKAGES $TOOLCHAIN $DEV_PACKAGES $remove \
        || die "apt couldn't install the build packages"
    # Packages that were already current were skipped above, but their
    # files are still deleted.
    # shellcheck disable=SC2086
    apt_prefetch --reinstall $TOOLCHAIN $DEV_PACKAGES \
        && apt_get install --reinstall $TOOLCHAIN $DEV_PACKAGES \
        || die "apt couldn't reinstall the compiler"
    compiler_works || die "the compiler still doesn't work; see the apt output above"
fi

# ------------------------------------------------------------- Python
if ! "$PY_BIN" -c 'import ssl, sqlite3, ctypes, zlib, bz2, lzma, uuid' 2> /dev/null \
        || [ "$("$PY_BIN" -c 'import platform; print(platform.python_version())')" != "$PY_VERSION" ]; then
    msg "Building Python ${PY_VERSION} (about an hour)"
    mkdir -p "$BUILD_DIR"
    tarball="${BUILD_DIR}/Python-${PY_VERSION}.tar.xz"
    if ! echo "${PY_SHA256}  ${tarball}" | sha256sum -c --status 2> /dev/null; then
        curl -fSL --cacert "$CA_BUNDLE" -o "$tarball" \
            "https://www.python.org/ftp/python/${PY_VERSION}/Python-${PY_VERSION}.tar.xz"
        echo "${PY_SHA256}  ${tarball}" | sha256sum -c --status \
            || die "Python-${PY_VERSION}.tar.xz failed its checksum"
    fi
    rm -rf "${BUILD_DIR}/Python-${PY_VERSION}"
    tar -xJf "$tarball" -C "$BUILD_DIR"
    (
        cd "${BUILD_DIR}/Python-${PY_VERSION}"
        # No --enable-optimizations: its profiling run would double the
        # build time for little gain in Moonraker.
        ./configure --prefix=/usr/local --with-ensurepip=install > configure.log 2>&1 \
            || { tail -30 configure.log; exit 1; }
        make -j"$(nproc)" > make.log 2>&1 || { tail -50 make.log; exit 1; }
        sudo make altinstall > install.log 2>&1 || { tail -30 install.log; exit 1; }
    ) || die "the Python build failed; logs are in ${BUILD_DIR}/Python-${PY_VERSION}"
    "$PY_BIN" -c 'import ssl, sqlite3, ctypes, zlib, bz2, lzma, uuid' \
        || die "Python ${PY_VERSION} is missing a module; see ${BUILD_DIR}/Python-${PY_VERSION}/make.log"
    rm -rf "$BUILD_DIR"
fi

# ---------------------------------------------------------- Moonraker
NEW_DIR="${MR_DIR}.new"
NEW_ENV="${MR_ENV}.new"
upstream_installed() { git -C "$MR_DIR" remote get-url origin 2> /dev/null | grep -q Arksine/moonraker; }

if upstream_installed; then
    # Already switched; just bring the venv up to date.
    NEW_DIR="$MR_DIR"
    NEW_ENV="$MR_ENV"
    git -C "$MR_DIR" fetch -q --tags origin
    git -C "$MR_DIR" checkout -q "$MOONRAKER_REF"
else
    msg "Downloading Moonraker ${MOONRAKER_REF}"
    rm -rf "$NEW_DIR"
    git clone -q "$MOONRAKER_REPO" "$NEW_DIR"
    git -C "$NEW_DIR" checkout -q "$MOONRAKER_REF"
fi

if [ ! -x "${NEW_ENV}/bin/python" ] \
        || ! "${NEW_ENV}/bin/python" -c "import sys; sys.exit(sys.version_info[:2] != (${PY_VERSION%.*}, ${PY_VERSION#*.}) and 1 or 0)" 2> /dev/null; then
    rm -rf "$NEW_ENV"
    "$PY_BIN" -m venv "$NEW_ENV"
fi
msg "Installing Moonraker's Python packages (Pillow and others compile here)"
"${NEW_ENV}/bin/pip" install -q --upgrade pip
# requirements.txt's --find-links is relative to the scripts folder.
(cd "${NEW_DIR}/scripts" && "${NEW_ENV}/bin/pip" install -q -r moonraker-requirements.txt) \
    || die "pip failed to install Moonraker's packages"
# Moonraker converts FLSun's LMDB database to SQLite on first start.
"${NEW_ENV}/bin/pip" install -q lmdb || die "pip failed to install lmdb"

# Plugins link their Moonraker components into the components folder.
# Carry the links over and keep git from listing them.
OLD_COMPONENTS="${MR_DIR}/moonraker/components"
NEW_COMPONENTS="${NEW_DIR}/moonraker/components"
if [ "$NEW_DIR" != "$MR_DIR" ]; then
    for link in "$OLD_COMPONENTS"/*; do
        [ -L "$link" ] || continue
        ln -sfn "$(readlink "$link")" "${NEW_COMPONENTS}/$(basename "$link")"
    done
fi
for link in "$NEW_COMPONENTS"/*; do
    [ -L "$link" ] || continue
    entry="moonraker/components/$(basename "$link")"
    grep -qxF "$entry" "${NEW_DIR}/.git/info/exclude" || echo "$entry" >> "${NEW_DIR}/.git/info/exclude"
done

msg "Updating the PolicyKit rules Moonraker uses to restart services"
(cd "$NEW_DIR" && ./scripts/set-policykit-rules.sh --disable-systemctl) > /dev/null \
    || msg "PolicyKit rules not updated; service restarts from Moonraker may ask for sudo"

if [ "$NEW_DIR" != "$MR_DIR" ]; then
    msg "Switching to the new Moonraker"
    sudo systemctl stop moonraker
    # Keep FLSun's copies only the first time; a later run's ~/moonraker
    # is already upstream.
    [ -e "${MR_DIR}.flsun" ] || mv "$MR_DIR" "${MR_DIR}.flsun"
    [ -e "${MR_ENV}.flsun" ] || mv "$MR_ENV" "${MR_ENV}.flsun"
    rm -rf "$MR_DIR" "$MR_ENV"
    if [ ! -e "${DATA_DIR}/database.flsun" ]; then
        cp -a "${DATA_DIR}/database" "${DATA_DIR}/database.flsun"
    fi
    mv "$NEW_DIR" "$MR_DIR"
    mv "$NEW_ENV" "$MR_ENV"
fi
# A venv's scripts hold its path; point them at the moved folder.
grep -rlF "${MR_ENV}.new" "${MR_ENV}/bin" 2> /dev/null \
    | xargs -r sed -i "s|${MR_ENV}\.new|${MR_ENV}|g"

msg "Starting Moonraker"
sudo systemctl restart moonraker
for _ in $(seq 60); do
    info=$(curl -s --max-time 2 http://127.0.0.1:7125/server/info || true)
    [ -n "$info" ] && break
    sleep 2
done
[ -n "$info" ] || die "Moonraker didn't start; see ${DATA_DIR}/logs/moonraker.log. uninstall.sh puts FLSun's version back."
echo "$info" | "$PY_BIN" -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    Moonraker", r.get("moonraker_version"), "| Klipper", r.get("klippy_state"))
for c in r.get("failed_components", []):
    print("    failed component:", c)
for w in r.get("warnings", []):
    print("    warning:", w)
'

msg "Done. FLSun's Moonraker is kept in ~/moonraker.flsun; ~/FLSUN_moonraker/uninstall.sh puts it back."
