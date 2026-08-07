#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_ARCHIVE" >&2
    exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${project_dir}/reader-shell/runtime.lock"
output=$1
revision=${BOKOPDS_SOURCE_REVISION:-}
epoch=${SOURCE_DATE_EPOCH:-}
stage=$(mktemp -d /tmp/bokopds-source.XXXXXX)
trap 'rm -rf "${stage}"' EXIT INT TERM HUP

[ -n "${revision}" ] || {
    echo "BOKOPDS_SOURCE_REVISION is required" >&2
    exit 1
}
[ -n "${epoch}" ] || {
    echo "SOURCE_DATE_EPOCH is required" >&2
    exit 1
}
git -C "${project_dir}" cat-file -e "${revision}^{commit}"
git -C "${project_dir}/vendor/NickelHook" rev-parse --verify HEAD >/dev/null

mkdir -p "${stage}/bokopds" "$(dirname -- "${output}")"
git -C "${project_dir}" archive "${revision}" |
    tar -xf - -C "${stage}/bokopds"
mkdir -p "${stage}/bokopds/vendor/NickelHook"
git -C "${project_dir}/vendor/NickelHook" archive HEAD |
    tar -xf - -C "${stage}/bokopds/vendor/NickelHook"
printf '%s\n' "${revision}" > "${stage}/bokopds/SOURCE_REVISION"
git -C "${project_dir}/vendor/NickelHook" rev-parse HEAD \
    > "${stage}/bokopds/vendor/NickelHook/SOURCE_REVISION"

source_cache="${project_dir}/build/runtime-cache/sources"
mkdir -p "${source_cache}" "${stage}/upstream-sources"
fetch_source() {
    name=$1
    url=$2
    expected=$3
    cached="${source_cache}/${name}"
    if [ ! -f "${cached}" ]; then
        curl --fail --location --retry 3 --output "${cached}.part" "${url}"
        mv -- "${cached}.part" "${cached}"
    fi
    actual=$(sha256sum "${cached}" | awk '{print $1}')
    [ "${actual}" = "${expected}" ] || {
        echo "source checksum mismatch for ${name}" >&2
        exit 1
    }
    cp "${cached}" "${stage}/upstream-sources/${name}"
}
fetch_source "koreader-${RUNTIME_VERSION}.tar.gz" \
    "${RUNTIME_SOURCE_URL}" "${RUNTIME_SOURCE_SHA256}"
fetch_source "koreader-base-${RUNTIME_BASE_COMMIT}.tar.gz" \
    "${RUNTIME_BASE_SOURCE_URL}" "${RUNTIME_BASE_SOURCE_SHA256}"
fetch_source "tar-${RUNTIME_TAR_VERSION}.tar.gz" \
    "${RUNTIME_TAR_SOURCE_URL}" "${RUNTIME_TAR_SOURCE_SHA256}"

cat > "${stage}/upstream-sources/SHA256SUMS" <<EOF
${RUNTIME_SOURCE_SHA256}  koreader-${RUNTIME_VERSION}.tar.gz
${RUNTIME_BASE_SOURCE_SHA256}  koreader-base-${RUNTIME_BASE_COMMIT}.tar.gz
${RUNTIME_TAR_SOURCE_SHA256}  tar-${RUNTIME_TAR_VERSION}.tar.gz
EOF

cat > "${stage}/LOCAL_BUILD_ONLY.txt" <<'EOF'
This source-materials archive supports local BokOPDS builds and auditing.
It is not a complete corresponding-source offer for every retained native
runtime library and must not be attached to a public binary release.
See bokopds/THIRD_PARTY.md for the current redistribution status.
EOF

tar -C "${stage}" --sort=name --mtime="@${epoch}" --owner=0 --group=0 \
    --numeric-owner -cf - LOCAL_BUILD_ONLY.txt bokopds upstream-sources |
    gzip -n > "${output}"

for required in LOCAL_BUILD_ONLY.txt bokopds/README.md bokopds/LICENSE bokopds/THIRD_PARTY.md \
    bokopds/reader-shell/runtime.lock bokopds/vendor/NickelHook/LICENSE \
    bokopds/SOURCE_REVISION bokopds/vendor/NickelHook/SOURCE_REVISION; do
    tar -tzf "${output}" | grep -Fx "${required}" >/dev/null || {
        echo "source archive is missing ${required}" >&2
        exit 1
    }
done
for required in upstream-sources/SHA256SUMS \
    "upstream-sources/koreader-${RUNTIME_VERSION}.tar.gz" \
    "upstream-sources/koreader-base-${RUNTIME_BASE_COMMIT}.tar.gz" \
    "upstream-sources/tar-${RUNTIME_TAR_VERSION}.tar.gz"; do
    tar -tzf "${output}" | grep -Fx "${required}" >/dev/null || {
        echo "source archive is missing ${required}" >&2
        exit 1
    }
done
echo "created ${output}"
