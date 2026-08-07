#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"${project_dir}/docs/assets/screenshots"}
runtime_dir="${project_dir}/build/reader-shell-emulator"
profile_root=$(mktemp -d "${project_dir}/build/.public-screenshots.XXXXXX")
catalog_url='https://www.gutenberg.org/ebooks.opds/?format=opds'
publication_url='https://www.gutenberg.org/ebooks/1342.opds'

cleanup() {
    rm -rf -- "${profile_root}"
}
trap cleanup EXIT HUP INT TERM

"${project_dir}/scripts/assemble-reader-shell.sh" "${runtime_dir}"

mkdir -p "${output_dir}"
profile="${profile_root}/shared"
mkdir -p "${profile}"
cp "${project_dir}/reader-shell/emulator/settings.reader.lua" \
    "${profile}/settings.reader.lua"
for screen in home feed selection detail; do
    BOKOPDS_EMULATOR_PROFILE="${profile}" \
    BOKOPDS_VIDEO_DRIVER=x11 \
    BOKOPDS_CAPTURE_CATALOG_URL="${catalog_url}" \
    BOKOPDS_CAPTURE_CATALOG_TITLE='Project Gutenberg' \
    BOKOPDS_CAPTURE_PUBLICATION_URL="${publication_url}" \
    BOKOPDS_CAPTURE_PUBLICATION_TITLE='Pride and Prejudice' \
    BOKOPDS_CAPTURE_SCREEN="${screen}" \
    BOKOPDS_CAPTURE_SCREENSHOT="${output_dir}/${screen}.png" \
    SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        xvfb-run -a "${project_dir}/scripts/run-reader-shell-emulator.sh" >/dev/null
    dimensions=$(identify -format '%wx%h' "${output_dir}/${screen}.png")
    if [ "${dimensions}" != "758x1024" ]; then
        echo "unexpected ${screen} screenshot size: ${dimensions}" >&2
        exit 1
    fi
done

echo "Captured public Project Gutenberg catalog screens in ${output_dir}"
