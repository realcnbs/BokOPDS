#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="${project_dir}/build/reader-shell-emulator"
test_root=$(mktemp -d "${project_dir}/build/.reader-shell-test.XXXXXX")
free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
server_port=$(free_port)
tls_port=$(free_port)
tls_wrong_port=$(free_port)
auth_port=$(free_port)
tls_unknown_port=$(free_port)
export BOKOPDS_ALLOW_INSECURE_LOOPBACK=1

cleanup() {
    for pid in ${server_pid:-} ${tls_pid:-} ${tls_wrong_pid:-} ${auth_pid:-} \
            ${tls_unknown_pid:-} ${guard_parent:-}; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    rm -rf -- "${test_root}"
}
trap cleanup EXIT HUP INT TERM

"${project_dir}/scripts/assemble-reader-shell.sh" "${runtime_dir}"

mkdir -p "${test_root}/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=BokOPDS test CA' -keyout "${test_root}/tls/ca.key" \
    -out "${test_root}/tls/ca.crt" >/dev/null 2>&1
make_certificate() {
    name=$1
    alt_name=$2
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${name}" \
        -keyout "${test_root}/tls/${name}.key" -out "${test_root}/tls/${name}.csr" \
        >/dev/null 2>&1
    printf '%s\n' "subjectAltName=${alt_name}" > "${test_root}/tls/${name}.ext"
    openssl x509 -req -days 1 -in "${test_root}/tls/${name}.csr" \
        -CA "${test_root}/tls/ca.crt" -CAkey "${test_root}/tls/ca.key" -CAcreateserial \
        -extfile "${test_root}/tls/${name}.ext" -out "${test_root}/tls/${name}.crt" \
        >/dev/null 2>&1
}
make_certificate valid 'IP:127.0.0.1'
make_certificate wrong 'DNS:wrong.example'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=unknown.example' \
    -addext 'subjectAltName=IP:127.0.0.1' -keyout "${test_root}/tls/unknown.key" \
    -out "${test_root}/tls/unknown.crt" >/dev/null 2>&1

python3 "${project_dir}/tests/opds_test_server.py" \
    --directory "${project_dir}/tests/fixtures" --port "${server_port}" \
    --cover "${project_dir}/assets/menu-book.png" \
    --redirect-url "http://127.0.0.1:${auth_port}/auth-check" &
server_pid=$!
python3 "${project_dir}/tests/opds_test_server.py" \
    --directory "${project_dir}/tests/fixtures" --port "${auth_port}" \
    --cover "${project_dir}/assets/menu-book.png" &
auth_pid=$!
python3 "${project_dir}/tests/opds_test_server.py" \
    --directory "${project_dir}/tests/fixtures" --port "${tls_port}" \
    --cover "${project_dir}/assets/menu-book.png" \
    --certfile "${test_root}/tls/valid.crt" --keyfile "${test_root}/tls/valid.key" &
tls_pid=$!
python3 "${project_dir}/tests/opds_test_server.py" \
    --directory "${project_dir}/tests/fixtures" --port "${tls_wrong_port}" \
    --cover "${project_dir}/assets/menu-book.png" \
    --certfile "${test_root}/tls/wrong.crt" --keyfile "${test_root}/tls/wrong.key" &
tls_wrong_pid=$!
python3 "${project_dir}/tests/opds_test_server.py" \
    --directory "${project_dir}/tests/fixtures" --port "${tls_unknown_port}" \
    --cover "${project_dir}/assets/menu-book.png" \
    --certfile "${test_root}/tls/unknown.crt" --keyfile "${test_root}/tls/unknown.key" &
tls_unknown_pid=$!

ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl --silent --fail "http://127.0.0.1:${server_port}/root.xml" >/dev/null &&
        curl --silent --fail "http://127.0.0.1:${auth_port}/auth-check" >/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "${ready}" != "1" ]; then
    echo "local OPDS test server did not start" >&2
    exit 1
fi

mkdir -p "${test_root}/service-profile" "${test_root}/downloads"
(
    cd "${runtime_dir}"
    KO_HOME="${test_root}/service-profile" \
    BOKOPDS_TEST_BASE_URL="http://127.0.0.1:${server_port}" \
    BOKOPDS_TLS_BASE_URL="https://127.0.0.1:${tls_port}" \
    BOKOPDS_TLS_WRONG_URL="https://127.0.0.1:${tls_wrong_port}" \
    BOKOPDS_TLS_UNKNOWN_URL="https://127.0.0.1:${tls_unknown_port}" \
    BOKOPDS_AUTH_BASE_URL="http://127.0.0.1:${auth_port}" \
    BOKOPDS_ALLOW_INSECURE_LOOPBACK=1 \
    SSL_CERT_FILE="${test_root}/tls/ca.crt" \
    BOKOPDS_TEST_DOWNLOAD_DIR="${test_root}/downloads" \
        ./luajit "${project_dir}/tests/reader_shell_service_test.lua"
)

mkdir -p "${test_root}/ui-profile"
cp "${project_dir}/reader-shell/emulator/settings.reader.lua" \
    "${test_root}/ui-profile/settings.reader.lua"
BOKOPDS_EMULATOR_PROFILE="${test_root}/ui-profile" \
BOKOPDS_VIDEO_DRIVER=x11 \
BOKOPDS_SELF_TEST="${test_root}/ui-self-test.txt" \
    xvfb-run -a "${project_dir}/scripts/run-reader-shell-emulator.sh"
grep -F "reader-shell-self-test: ok" "${test_root}/ui-self-test.txt" >/dev/null

mkdir -p "${test_root}/cancel-profile"
cp "${project_dir}/reader-shell/emulator/settings.reader.lua" \
    "${test_root}/cancel-profile/settings.reader.lua"
BOKOPDS_EMULATOR_PROFILE="${test_root}/cancel-profile" \
BOKOPDS_VIDEO_DRIVER=x11 \
BOKOPDS_CANCELLATION_TEST="${test_root}/cancellation-test.txt" \
BOKOPDS_CANCELLATION_URL="http://127.0.0.1:${server_port}/slow" \
    xvfb-run -a "${project_dir}/scripts/run-reader-shell-emulator.sh"
grep -F "reader-shell-cancellation-test: ok" \
    "${test_root}/cancellation-test.txt" >/dev/null

mkdir -p "${test_root}/guard-profile"
(
    cd "${runtime_dir}"
    exec env KO_HOME="${test_root}/guard-profile" \
        BOKOPDS_GUARD_MARKER="${test_root}/orphan-marker" \
        BOKOPDS_GUARD_PID_FILE="${test_root}/guard-child.pid" \
        ./luajit "${project_dir}/tests/subprocess_guard_test.lua"
) &
guard_parent=$!
guard_ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "${test_root}/guard-child.pid" ]; then guard_ready=1; break; fi
    sleep 0.1
done
if [ "${guard_ready}" != "1" ]; then
    echo "subprocess guard test did not start" >&2
    exit 1
fi
kill -KILL "${guard_parent}"
wait "${guard_parent}" 2>/dev/null || true
sleep 4
if [ -e "${test_root}/orphan-marker" ]; then
    echo "subprocess survived a hard parent crash" >&2
    exit 1
fi

mkdir -p "${project_dir}/build/reader-shell-screenshots"
for screen in home offline form search feed feed-scroll selection batch-download batch-folder bulk-busy download-complete download-complete-page2 preferences detail detail-scroll bookmarks bookmark-rename bookmark-feed busy; do
    profile="${test_root}/visual-${screen}"
    mkdir -p "${profile}"
    cp "${project_dir}/reader-shell/emulator/settings.reader.lua" "${profile}/settings.reader.lua"
    screenshot="${project_dir}/build/reader-shell-screenshots/${screen}.png"
    demo_screen="${screen}"
    if [ "${screen}" = "home" ]; then demo_screen=""; fi
    BOKOPDS_EMULATOR_PROFILE="${profile}" \
    BOKOPDS_VIDEO_DRIVER=x11 \
    BOKOPDS_DEMO=library \
    BOKOPDS_DEMO_SCREEN="${demo_screen}" \
    BOKOPDS_SCREENSHOT="${screenshot}" \
        xvfb-run -a "${project_dir}/scripts/run-reader-shell-emulator.sh" >/dev/null
    dimensions=$(identify -format '%wx%h' "${screenshot}")
    if [ "${dimensions}" != "758x1024" ]; then
        echo "unexpected screenshot size for ${screen}: ${dimensions}" >&2
        exit 1
    fi
done

# Blocking operations must cover the complete viewport. In particular, a busy
# view opened from a deep feed must not retain the first 96 pixels and cut a
# 124-pixel breadcrumb header in two.
busy_top=$(magick "${project_dir}/build/reader-shell-screenshots/bulk-busy.png" \
    -format '%[pixel:p{10,10}]' info:)
busy_body=$(magick "${project_dir}/build/reader-shell-screenshots/bulk-busy.png" \
    -format '%[pixel:p{10,180}]' info:)
if [ "${busy_top}" != "${busy_body}" ]; then
    echo "bulk busy overlay does not cover the complete screen" >&2
    exit 1
fi

for dimensions in 600x800 1072x1448 1404x1872; do
    width=${dimensions%x*}
    height=${dimensions#*x}
    profile="${test_root}/size-${dimensions}"
    mkdir -p "${profile}"
    cp "${project_dir}/reader-shell/emulator/settings.reader.lua" "${profile}/settings.reader.lua"
    sed -i \
        -e "s/\[\"height\"\] = 1024/\[\"height\"\] = ${height}/" \
        -e "s/\[\"width\"\] = 758/\[\"width\"\] = ${width}/" \
        "${profile}/settings.reader.lua"
    screenshot="${project_dir}/build/reader-shell-screenshots/home-${dimensions}.png"
    BOKOPDS_EMULATOR_PROFILE="${profile}" \
    BOKOPDS_VIDEO_DRIVER=x11 \
    BOKOPDS_DEMO=library \
    BOKOPDS_SCREENSHOT="${screenshot}" \
        xvfb-run -a "${project_dir}/scripts/run-reader-shell-emulator.sh" >/dev/null
    actual=$(identify -format '%wx%h' "${screenshot}")
    if [ "${actual}" != "${dimensions}" ]; then
        echo "unexpected responsive screenshot size: ${actual}, wanted ${dimensions}" >&2
        exit 1
    fi
done

echo "reader-shell-emulator-tests: ok"
