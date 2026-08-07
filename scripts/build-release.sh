#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "${project_dir}/VERSION")
output_dir=${BOKOPDS_RELEASE_OUTPUT_DIR:-"${project_dir}/dist"}
runtime="${project_dir}/build/reader-shell-device"
archive="${output_dir}/KoboRoot.tgz"
checksums="${output_dir}/SHA256SUMS"
hook="${project_dir}/device-hook/libbokopds.so"
container_runtime=${CONTAINER_RUNTIME:-docker}
toolchain_image=ghcr.io/pgaskin/nickeltc@sha256:3296eb400d270cfd26f5773ab09625d4469f85680b3a191951dfb78d8ade7840

case "${version}" in *[!0-9A-Za-z.-]*|'') echo "invalid VERSION" >&2; exit 1;; esac
command -v "${container_runtime}" >/dev/null 2>&1 || {
    echo "${container_runtime} is required to build the device hook" >&2; exit 1; }

mkdir -p "${output_dir}"
rm -f "${archive}" "${output_dir}/compatibility.json" \
    "${output_dir}/COMPATIBILITY.md" "${checksums}"

if [ -n "$(git -C "${project_dir}" status --porcelain --untracked-files=normal)" ]; then
    echo "commit or stash source changes before building a release" >&2
    exit 1
fi
BOKOPDS_SOURCE_REVISION=$(git -C "${project_dir}" rev-parse HEAD)
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "${project_dir}" show -s --format=%ct HEAD 2>/dev/null || printf 0)}
export BOKOPDS_SOURCE_REVISION SOURCE_DATE_EPOCH

"${project_dir}/scripts/generate-compatibility.py" --check
"${project_dir}/scripts/assemble-reader-shell-device.sh" "${runtime}"
"${project_dir}/scripts/generate-compatibility.py" --check \
    --runtime-device-lua "${runtime}/frontend/device/kobo/device.lua"
"${container_runtime}" run --rm \
    -v "${project_dir}:/src" -w /src/device-hook \
    "${toolchain_image}" make clean all
[ -f "${hook}" ] || { echo "hook build produced no ${hook}" >&2; exit 1; }
"${project_dir}/scripts/build-package.sh" "${runtime}" "${hook}" "${archive}"
"${project_dir}/scripts/verify-package.sh" "${archive}"
cp "${project_dir}/compatibility.json" "${output_dir}/compatibility.json"
cp "${project_dir}/COMPATIBILITY.md" "${output_dir}/COMPATIBILITY.md"
(
    cd "${output_dir}"
    sha256sum KoboRoot.tgz compatibility.json COMPATIBILITY.md > SHA256SUMS
)
echo "release artifacts created in ${output_dir}"
