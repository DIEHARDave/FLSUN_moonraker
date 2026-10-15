#!/bin/bash
# Packs the prebuilt files install.sh downloads, from a T1 Pro that
# FLSUN_moonraker has already installed on (so Python is built and
# Moonraker's packages are compiled). Run as pi:
#   ~/FLSUN_moonraker/tools/build-prebuilt.sh
# Writes to ~/prebuilt:
#   python-<version>-armv7l-buster.tar.xz          Python in /usr/local
#   moonraker-<tag>-wheels-cp313-armv7l.tar        wheels for that Moonraker
# Upload both to a new GitHub release and update PREBUILT_URL and the
# hashes in install.sh; the hashes are printed at the end.

set -e

MR_DIR="${HOME}/moonraker"
MR_ENV="${HOME}/moonraker-env"
OUT="${HOME}/prebuilt"
PY_BIN="/usr/local/bin/python3.13"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$PY_BIN" ] || die "$PY_BIN not found; run install.sh first"
[ -x "${MR_ENV}/bin/pip" ] || die "${MR_ENV} not found; run install.sh first"
py_version=$("$PY_BIN" -c 'import platform; print(platform.python_version())')
mr_tag=$(git -C "$MR_DIR" describe --tags --exact-match 2> /dev/null) \
    || die "~/moonraker isn't at a release tag; install one with MOONRAKER_REF=<tag>"
mkdir -p "$OUT"

msg "Packing Python ${py_version}"
# No test suite, and no site-packages: venvs get pip from ensurepip.
py_tar="${OUT}/python-${py_version}-armv7l-buster.tar.xz"
(cd / && tar -cf - \
    --exclude=usr/local/lib/python3.13/test \
    --exclude=usr/local/lib/python3.13/site-packages \
    usr/local/bin/python3.13 usr/local/bin/python3.13-config \
    usr/local/bin/pydoc3.13 usr/local/bin/idle3.13 \
    usr/local/lib/python3.13 usr/local/lib/libpython3.13.a \
    usr/local/lib/pkgconfig/python-3.13.pc \
    usr/local/lib/pkgconfig/python-3.13-embed.pc \
    usr/local/include/python3.13 usr/local/share/man/man1/python3.13.1) \
    | xz -T0 -6 > "$py_tar"

msg "Building wheels for Moonraker ${mr_tag}"
rm -rf "${OUT}/wheelhouse"
# requirements.txt's --find-links is relative to the scripts folder.
(cd "${MR_DIR}/scripts" && "${MR_ENV}/bin/pip" wheel -q -w "${OUT}/wheelhouse" \
    -r moonraker-requirements.txt lmdb)
wheels_tar="${OUT}/moonraker-${mr_tag}-wheels-cp313-armv7l.tar"
tar -C "$OUT" -cf "$wheels_tar" wheelhouse
rm -rf "${OUT}/wheelhouse"

msg "Done:"
sha256sum "$py_tar" "$wheels_tar"
