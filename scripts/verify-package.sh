#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 PACKAGE_TGZ [READER_STORAGE_ROOT]" >&2
    exit 2
fi

package=$1
reader_root=${2:-}
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${project_dir}/reader-shell/runtime.lock"
stage=$(mktemp -d /tmp/bokopds-verify.XXXXXX)
trap 'rm -rf "${stage}"' EXIT INT TERM HUP

[ -f "${package}" ] || { echo "package does not exist: ${package}" >&2; exit 1; }
tar -tzf "${package}" | while IFS= read -r member; do
    normalized=${member#./}
    case "${normalized}" in /*|../*|*/../*|*/..) echo "unsafe package member: ${member}" >&2; exit 1;; esac
done
tar -tvzf "${package}" | while IFS= read -r details; do
    case "$(printf '%s' "${details}" | cut -c 1)" in -|d) ;; *) echo "package contains a link or special file" >&2; exit 1;; esac
done
tar -xzf "${package}" -C "${stage}"

app="${stage}/mnt/onboard/.adds/bokopds"
for relative in \
    reader.lua bokopds.lua koreader.sh luajit tar launch.sh menu-book.png menu-book-active.png \
    VERSION SOURCE_REVISION COMPATIBILITY.md compatibility.json COPYING \
    data/ca-bundle.crt frontend/apps/bokopds/main.lua \
    frontend/apps/bokopds/shell.lua frontend/apps/bokopds/catalog_service.lua \
    frontend/apps/bokopds/secure_http.lua frontend/apps/bokopds/subprocess_guard.lua \
    frontend/apps/bokopds/opdsparser.lua \
    licenses/BokOPDS.txt licenses/THIRD_PARTY.md licenses/sbom.cdx.json \
    licenses/Lucide.txt \
    licenses/Lucide-NOTICE.md licenses/NickelHook.txt \
    data/KoboUSBMS.tar.gz; do
    [ -f "${app}/${relative}" ] || { echo "missing package path: ${relative}" >&2; exit 1; }
done
source_revision=$(cat "${app}/SOURCE_REVISION")
cmp -s "${app}/compatibility.json" "${project_dir}/compatibility.json" || {
    echo "packaged compatibility manifest differs from the generated source" >&2; exit 1; }
cmp -s "${app}/COMPATIBILITY.md" "${project_dir}/COMPATIBILITY.md" || {
    echo "packaged compatibility document differs from the generated source" >&2; exit 1; }
python3 -m json.tool "${app}/compatibility.json" >/dev/null || {
    echo "packaged compatibility manifest is invalid JSON" >&2; exit 1; }
if [ "${BOKOPDS_ALLOW_TEST_ARTIFACTS:-0}" != "1" ] &&
    ! printf '%s\n' "${source_revision}" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "package has no valid committed source revision" >&2
    exit 1
fi
hook="${stage}/usr/local/Kobo/imageformats/libbokopds.so"
[ -f "${hook}" ] || { echo "missing packaged hook" >&2; exit 1; }
[ ! -e "${app}/bokopds" ] || { echo "obsolete duplicate application binary is present" >&2; exit 1; }
[ ! -e "${app}/render-profile" ] || { echo "obsolete render profile is present" >&2; exit 1; }
[ ! -d "${app}/resources/ime" ] || { echo "obsolete IME payload is present" >&2; exit 1; }
[ ! -e "${app}/ffi/__gc.lua" ] || { echo "unlicensed finalizer helper is present" >&2; exit 1; }
[ ! -d "${app}/common/lj-wpaclient" ] || { echo "unlicensed Wi-Fi client is present" >&2; exit 1; }

if [ "${BOKOPDS_ALLOW_TEST_ARTIFACTS:-0}" != "1" ]; then
    grep -F 'RenderImage:renderImageFile(path, false' \
        "${app}/frontend/apps/bokopds/shell.lua" >/dev/null || {
            echo "cover renderer no longer forces static-frame decoding" >&2; exit 1; }
    [ "$(sha256sum "${app}/tar" | awk '{print $1}')" = "${RUNTIME_TAR_BINARY_SHA256}" ] || {
        echo "packaged GNU tar does not match the pinned runtime binary" >&2; exit 1; }
    file "${hook}" | grep -qi 'ELF.*ARM' || { echo "packaged hook is not ARM" >&2; exit 1; }
    find "${app}" -type f | while IFS= read -r object; do
        if file "${object}" | grep -q 'ELF'; then
            file "${object}" | grep -qi 'ELF 32-bit.*ARM' || {
                echo "packaged runtime object is not 32-bit ARM: ${object#${app}/}" >&2; exit 1; }
            newest_glibc=$(readelf --version-info "${object}" 2>/dev/null |
                sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -n 1)
            if [ -n "${newest_glibc}" ] &&
                [ "$(printf '%s\n%s\n' "${newest_glibc}" 2.15 | sort -V | tail -n 1)" != "2.15" ]; then
                echo "runtime requires unsupported GLIBC_${newest_glibc}: ${object#${app}/}" >&2
                exit 1
            fi
            readelf -d "${object}" 2>/dev/null |
                sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' |
                while IFS= read -r dependency; do
                    case "${dependency}" in
                        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libgcc_s.so.*|ld-linux*.so.*) ;;
                        *)
                            if ! find "${app}" -type f -name "${dependency}" -print -quit | grep -q .; then
                                echo "missing runtime dependency ${dependency} for ${object#${app}/}" >&2
                                exit 1
                            fi
                            ;;
                    esac
                done
        fi
    done
fi

[ -x "${app}/launch.sh" ] && [ -x "${app}/luajit" ] || {
    echo "packaged launchers are not executable" >&2; exit 1; }
cmp -s "${app}/reader.lua" "${app}/bokopds.lua" || {
    echo "device entry point does not match tested BokOPDS shell" >&2; exit 1; }
if find "${stage}" -type f ! -path "${app}/*" ! -path "${hook}" | grep -q .; then
    echo "package contains files outside expected roots" >&2; exit 1
fi

if [ -n "${reader_root}" ] && [ -e "${reader_root}/.adds/bokopds" ]; then
    echo "reader storage already contains BokOPDS; installation will be an update" >&2
fi
echo "package verified"
