#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${project_dir}/reader-shell/runtime.lock"

cache_dir="${project_dir}/build/runtime-cache"
output_dir="${1:-${project_dir}/build/reader-shell-emulator}"
archive="${cache_dir}/reader-shell-${RUNTIME_VERSION}-desktop.tar.xz"
work_dir=$(mktemp -d "${project_dir}/build/.reader-shell.XXXXXX")

cleanup() {
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "${cache_dir}" "${project_dir}/build"
if [ ! -f "${archive}" ]; then
    curl --fail --location --retry 3 --output "${archive}.part" "${RUNTIME_DESKTOP_URL}"
    mv -- "${archive}.part" "${archive}"
fi

actual_sha=$(sha256sum "${archive}" | awk '{print $1}')
if [ "${actual_sha}" != "${RUNTIME_DESKTOP_SHA256}" ]; then
    echo "reader runtime checksum mismatch" >&2
    exit 1
fi

mkdir -p "${work_dir}/unpacked" "${work_dir}/runtime"
tar -xJf "${archive}" -C "${work_dir}/unpacked"
cp -a "${work_dir}/unpacked/lib/koreader/." "${work_dir}/runtime/"
cp -a "${project_dir}/reader-shell/overlay/." "${work_dir}/runtime/"
rm -rf -- "${work_dir}/runtime/common/lj-wpaclient"
rm -f -- "${work_dir}/runtime/ffi/__gc.lua"

# Keep the mature parser beside the BokOPDS shell, then remove unrelated apps.
cp "${work_dir}/runtime/plugins/opds.koplugin/opdsparser.lua" \
    "${work_dir}/runtime/frontend/apps/bokopds/opdsparser.lua"
cp -a "${work_dir}/runtime/plugins/autosuspend.koplugin" \
    "${work_dir}/autosuspend.koplugin"
mkdir -p "${work_dir}/service-support/apps/filemanager"
cp "${work_dir}/runtime/frontend/apps/filemanager/filemanagerutil.lua" \
    "${work_dir}/service-support/apps/filemanager/filemanagerutil.lua"
rm -rf -- \
    "${work_dir}/runtime/frontend/apps/cloudstorage" \
    "${work_dir}/runtime/frontend/apps/filemanager" \
    "${work_dir}/runtime/frontend/apps/reader" \
    "${work_dir}/runtime/plugins" \
    "${work_dir}/runtime/data/hyph" \
    "${work_dir}/runtime/l10n" \
    "${work_dir}/runtime/resources/quickstart" \
    "${work_dir}/runtime/sdcv" \
    "${work_dir}/runtime/tools" \
    "${work_dir}/runtime/reader.lua" \
    "${work_dir}/runtime/koreader.sh" \
    "${work_dir}/runtime/update_once.marker"
mkdir -p "${work_dir}/runtime/plugins"
mv "${work_dir}/autosuspend.koplugin" "${work_dir}/runtime/plugins/"
mkdir -p "${work_dir}/runtime/frontend/apps/filemanager"
mv "${work_dir}/service-support/apps/filemanager/filemanagerutil.lua" \
    "${work_dir}/runtime/frontend/apps/filemanager/filemanagerutil.lua"
chmod +x "${work_dir}/runtime/bokopds.lua"

if [ -e "${output_dir}" ]; then
    rm -rf -- "${output_dir}"
fi
mkdir -p "$(dirname -- "${output_dir}")"
mv -- "${work_dir}/runtime" "${output_dir}"

printf '%s\n' "Assembled ${RUNTIME_VERSION} desktop shell at ${output_dir}"
