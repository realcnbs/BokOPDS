#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "${project_dir}/VERSION")
output_dir=${BOKOPDS_RELEASE_OUTPUT_DIR:-"${project_dir}/dist"}
runtime="${project_dir}/build/reader-shell-device"
archive="${output_dir}/bokopds-local-device-${version}.tgz"
source_archive="${output_dir}/bokopds-local-source-materials-${version}.tgz"
hook="${project_dir}/device-hook/libbokopds.so"
container_runtime=${CONTAINER_RUNTIME:-docker}

case "${version}" in *[!0-9A-Za-z.-]*|'') echo "invalid VERSION" >&2; exit 1;; esac
command -v "${container_runtime}" >/dev/null 2>&1 || {
    echo "${container_runtime} is required to build the device hook" >&2; exit 1; }

if [ "${BOKOPDS_IMMUTABLE_BUILD:-0}" != "1" ]; then
    git -C "${project_dir}" rev-parse --verify HEAD >/dev/null 2>&1 || {
        echo "a committed source revision is required for a reproducible local build" >&2; exit 1; }
    if [ -n "$(git -C "${project_dir}" status --porcelain --untracked-files=normal)" ]; then
        echo "the source tree must be clean before building a local device package" >&2
        exit 1
    fi
    revision=$(git -C "${project_dir}" rev-parse HEAD)
    snapshot_root=$(mktemp -d /tmp/bokopds-release.XXXXXX)
    snapshot="${snapshot_root}/source"
    cleanup_snapshot() {
        git -C "${project_dir}" worktree remove --force "${snapshot}" >/dev/null 2>&1 || true
        rm -rf -- "${snapshot_root}"
    }
    trap cleanup_snapshot EXIT INT TERM HUP
    git -C "${project_dir}" worktree add --detach "${snapshot}" "${revision}" >/dev/null
    git -C "${snapshot}" submodule update --init --recursive
    mkdir -p "${snapshot}/build"
    if [ -d "${project_dir}/build/runtime-cache" ]; then
        ln -s "${project_dir}/build/runtime-cache" "${snapshot}/build/runtime-cache"
    fi
    BOKOPDS_IMMUTABLE_BUILD=1 \
    BOKOPDS_RELEASE_OUTPUT_DIR="${output_dir}" \
    BOKOPDS_SOURCE_REVISION="${revision}" \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${project_dir}" show -s --format=%ct "${revision}")}" \
    CONTAINER_RUNTIME="${container_runtime}" \
        "${snapshot}/scripts/build-release.sh"
    exit 0
fi

[ -n "${BOKOPDS_SOURCE_REVISION:-}" ] || {
    echo "immutable build has no source revision" >&2; exit 1; }
[ "$(git -C "${project_dir}" rev-parse HEAD)" = "${BOKOPDS_SOURCE_REVISION}" ] || {
    echo "immutable build revision mismatch" >&2; exit 1; }
if [ -n "$(git -C "${project_dir}" status --porcelain --untracked-files=normal)" ]; then
    echo "immutable source worktree became dirty" >&2
    exit 1
fi
export BOKOPDS_SOURCE_REVISION

"${project_dir}/scripts/test-reader-shell-emulator.sh"
"${project_dir}/scripts/assemble-reader-shell-device.sh" "${runtime}"
"${container_runtime}" run --rm \
    -v "${project_dir}:/src" -w /src/device-hook \
    ghcr.io/pgaskin/nickeltc@sha256:3296eb400d270cfd26f5773ab09625d4469f85680b3a191951dfb78d8ade7840 \
    make clean all

[ -f "${hook}" ] || { echo "hook build produced no ${hook}" >&2; exit 1; }
[ -n "${SOURCE_DATE_EPOCH:-}" ] || {
    echo "immutable build has no source timestamp" >&2; exit 1; }
export SOURCE_DATE_EPOCH
"${project_dir}/scripts/build-package.sh" "${runtime}" "${hook}" "${archive}"
"${project_dir}/scripts/verify-package.sh" "${archive}"
"${project_dir}/scripts/build-source-archive.sh" "${source_archive}"
(
    cd "${output_dir}"
    sha256sum "$(basename -- "${archive}")" > "$(basename -- "${archive}").sha256"
    sha256sum "$(basename -- "${source_archive}")" > \
        "$(basename -- "${source_archive}").sha256"
)
echo "local-install artifacts: ${archive}, ${source_archive}, and checksums"
