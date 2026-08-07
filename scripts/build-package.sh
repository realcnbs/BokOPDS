#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 DEVICE_RUNTIME_DIRECTORY HOOK_LIBRARY OUTPUT_ARCHIVE" >&2
    exit 2
fi

runtime=$1
hook=$2
output=$3
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_revision=${BOKOPDS_SOURCE_REVISION:-}
stage=$(mktemp -d /tmp/bokopds-package.XXXXXX)
trap 'rm -rf "${stage}"' EXIT INT TERM HUP

if [ ! -d "${runtime}" ] || [ ! -f "${runtime}/reader.lua" ] ||
    [ ! -x "${runtime}/luajit" ]; then
    echo "device runtime is incomplete: ${runtime}" >&2
    exit 1
fi
if [ ! -f "${hook}" ]; then
    echo "hook library does not exist: ${hook}" >&2
    exit 1
fi
if [ -z "${source_revision}" ]; then
    if [ "${BOKOPDS_ALLOW_TEST_ARTIFACTS:-0}" = "1" ]; then
        source_revision=test-artifact
    else
        echo "BOKOPDS_SOURCE_REVISION is required for a reproducible package" >&2
        exit 1
    fi
fi
if [ "${BOKOPDS_ALLOW_TEST_ARTIFACTS:-0}" != "1" ] &&
    ! file "${hook}" | grep -qi 'ELF.*ARM'; then
    echo "hook artifact is not an ARM ELF library" >&2
    exit 1
fi

app="${stage}/mnt/onboard/.adds/bokopds"
mkdir -p "${app}"
cp -a "${runtime}/." "${app}/"
install -m755 "${project_dir}/device-runtime/launch.sh" "${app}/launch.sh"
install -m644 "${project_dir}/assets/menu-book.png" "${app}/menu-book.png"
install -m644 "${project_dir}/assets/menu-book-active.png" "${app}/menu-book-active.png"
install -Dm644 "${project_dir}/VERSION" "${app}/VERSION"
install -Dm644 "${project_dir}/compatibility.json" "${app}/compatibility.json"
install -Dm644 "${project_dir}/COMPATIBILITY.md" "${app}/COMPATIBILITY.md"
printf '%s\n' "${source_revision}" > "${app}/SOURCE_REVISION"
install -Dm644 "${project_dir}/LICENSE" "${app}/licenses/BokOPDS.txt"
install -Dm644 "${project_dir}/THIRD_PARTY.md" "${app}/licenses/THIRD_PARTY.md"
install -Dm644 "${project_dir}/sbom.cdx.json" "${app}/licenses/sbom.cdx.json"
install -Dm644 "${project_dir}/vendor/lucide/LICENSE" "${app}/licenses/Lucide.txt"
install -Dm644 "${project_dir}/vendor/lucide/NOTICE.md" "${app}/licenses/Lucide-NOTICE.md"
install -Dm644 "${project_dir}/vendor/NickelHook/LICENSE" "${app}/licenses/NickelHook.txt"
install -Dm644 "${hook}" "${stage}/usr/local/Kobo/imageformats/libbokopds.so"

mkdir -p "$(dirname -- "${output}")"
epoch=${SOURCE_DATE_EPOCH:-0}
tar -C "${stage}" --sort=name --mtime="@${epoch}" --owner=0 --group=0 \
    --numeric-owner -cf - . | gzip -n > "${output}"
echo "created ${output}"
