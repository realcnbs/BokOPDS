#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="${project_dir}/build/reader-shell-emulator"
profile_dir=$(mktemp -d "${project_dir}/build/.live-catalogs.XXXXXX")

cleanup() {
    rm -rf -- "${profile_dir}"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "${runtime_dir}/luajit" ]; then
    "${project_dir}/scripts/assemble-reader-shell.sh" "${runtime_dir}"
fi

ca_file=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}
if [ ! -f "${ca_file}" ]; then
    echo "CA bundle not found: ${ca_file}" >&2
    exit 1
fi

cd "${runtime_dir}"
KO_HOME="${profile_dir}" SSL_CERT_FILE="${ca_file}" \
    ./luajit "${project_dir}/tests/live_catalog_test.lua"

