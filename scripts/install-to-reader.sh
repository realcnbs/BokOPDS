#!/bin/sh
set -eu
umask 077

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 PACKAGE_TGZ READER_STORAGE_ROOT [LOCAL_BACKUP_DIRECTORY]" >&2
    exit 2
fi

package=$1
reader_root=$2
backup_directory=${3:-"$(pwd)/bokopds-reader-backups"}
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
system_directory="${reader_root}/.kobo"
version_file="${system_directory}/version"
update_file="${system_directory}/KoboRoot.tgz"
partial_update="${update_file}.bokopds-part"
partial_created=false

cleanup() {
    if [ "${partial_created}" = "true" ]; then
        rm -f "${partial_update}"
    fi
}
trap cleanup EXIT INT TERM HUP

if [ ! -d "${reader_root}" ] || [ ! -d "${system_directory}" ] ||
    [ ! -f "${version_file}" ]; then
    echo "the selected path does not look like mounted reader storage" >&2
    exit 1
fi

firmware=$(awk -F, 'NR == 1 { print $3 }' "${version_file}")
if ! printf '%s\n' "${firmware}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "could not determine firmware version; installation was not staged" >&2
    exit 1
fi
if [ "${firmware}" != "4.38.23697" ]; then
    echo "firmware ${firmware} is not in the tested compatibility list (4.38.23697)" >&2
    exit 1
fi
hardware_id=$(awk -F, 'NR == 1 {
    count = split($NF, identifier_parts, "-")
    value = identifier_parts[count]
    sub(/^0+/, "", value)
    print value
}' "${version_file}")
if [ "${hardware_id}" != "389" ]; then
    echo "this package is currently restricted to the tested hardware family (ID 389)" >&2
    exit 1
fi

if [ -e "${update_file}" ] || [ -e "${partial_update}" ]; then
    echo "reader storage already contains a pending system update; nothing was changed" >&2
    exit 1
fi
if [ -e "${reader_root}/.adds/bokopds/uninstall" ]; then
    echo "BokOPDS uninstall is pending; restart the reader before installing again" >&2
    exit 1
fi

"${project_dir}/scripts/verify-package.sh" "${package}" "${reader_root}"

package_bytes=$(wc -c < "${package}")
unpacked_bytes=$(gzip -cd "${package}" | wc -c)
available_kib=$(df -Pk "${system_directory}" | awk 'NR == 2 { print $4 }')
required_kib=$(((package_bytes + unpacked_bytes) / 1024 + 8192))
if [ "${available_kib}" -lt "${required_kib}" ]; then
    echo "reader storage does not have enough free space for a safe staged copy" >&2
    exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ "${BOKOPDS_INSTALL_DRY_RUN:-0}" = "1" ]; then
    echo "dry run passed for firmware ${firmware}; reader storage was not modified"
    exit 0
fi

backup_path="${backup_directory}/${timestamp}-$$"
mkdir -p "${backup_path}"
cp -p "${version_file}" "${backup_path}/version"
config_file="${system_directory}/Kobo/Kobo eReader.conf"
if [ -f "${config_file}" ]; then
    cp -p "${config_file}" "${backup_path}/Kobo eReader.conf"
fi
for database_file in KoboReader.sqlite KoboReader.sqlite-wal KoboReader.sqlite-shm; do
    if [ -f "${system_directory}/${database_file}" ]; then
        cp -p "${system_directory}/${database_file}" "${backup_path}/${database_file}"
    fi
done
if [ -d "${reader_root}/.adds/bokopds" ]; then
    tar -C "${reader_root}" -czf "${backup_path}/bokopds-installation.tgz" .adds/bokopds
    find "${reader_root}/.adds/bokopds" -type f -print0 | sort -z |
        xargs -0 sha256sum > "${backup_path}/bokopds-installation.sha256"
fi
sha256sum "${package}" > "${backup_path}/package.sha256"
find "${backup_path}" -maxdepth 1 -type f ! -name backup.sha256 -print0 | sort -z |
    xargs -0 sha256sum > "${backup_path}/backup.sha256"
echo "saved recovery files to ${backup_path}"

partial_created=true
cp "${package}" "${partial_update}"
if ! cmp -s "${package}" "${partial_update}"; then
    echo "staged package verification failed" >&2
    exit 1
fi
mv "${partial_update}" "${update_file}"
partial_created=false
sync "${update_file}" 2>/dev/null || sync
trap - EXIT INT TERM HUP

echo "installation staged for firmware ${firmware}"
echo "safely eject the reader; it should install the update and restart"
