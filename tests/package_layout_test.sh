#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d /tmp/bokopds-package-test.XXXXXX)
launch_runtime=""
cleanup() {
    if [ -n "${launch_runtime}" ]; then kill "${launch_runtime}" 2>/dev/null || true; fi
    rm -rf "${temp}"
}
trap cleanup EXIT INT TERM HUP

runtime="${temp}/runtime"
mkdir -p "${runtime}/data" "${runtime}/frontend/apps/bokopds"
printf '%s\n' '#!/bin/sh' > "${runtime}/luajit"
printf '%s\n' 'test entry' > "${runtime}/reader.lua"
cp "${runtime}/reader.lua" "${runtime}/bokopds.lua"
printf '%s\n' '#!/bin/sh' > "${runtime}/koreader.sh"
printf '%s\n' '#!/bin/sh' > "${runtime}/tar"
printf '%s\n' 'test USBMS data' > "${runtime}/data/KoboUSBMS.tar.gz"
printf '%s\n' 'test CA' > "${runtime}/data/ca-bundle.crt"
printf '%s\n' 'test copying' > "${runtime}/COPYING"
for source in main shell catalog_service secure_http subprocess_guard opdsparser; do
    printf '%s\n' 'return {}' > "${runtime}/frontend/apps/bokopds/${source}.lua"
done
chmod +x "${runtime}/luajit" "${runtime}/koreader.sh" "${runtime}/tar"
printf '%s\n' 'test hook' > "${temp}/libbokopds.so"

BOKOPDS_ALLOW_TEST_ARTIFACTS=1 "${project_dir}/scripts/build-package.sh" \
    "${runtime}" "${temp}/libbokopds.so" "${temp}/bokopds-device.tgz"
BOKOPDS_ALLOW_TEST_ARTIFACTS=1 "${project_dir}/scripts/verify-package.sh" \
    "${temp}/bokopds-device.tgz"
test -s "${temp}/bokopds-device.tgz"
if tar -tzf "${temp}/bokopds-device.tgz" |
        grep -Eq '/bokopds$|render-profile|resources/ime|ffi/__gc\.lua|common/lj-wpaclient'; then
    echo "package retained an obsolete release artifact" >&2
    exit 1
fi

mkdir -p "${temp}/reader/.kobo" "${temp}/reader/.adds/bokopds/data"
printf '%s\n' 'existing application configuration' > \
    "${temp}/reader/.adds/bokopds/data/settings.lua"
printf '%s\n' 'N000,4.9.77,4.38.23697,4.9.77,4.9.77,00000000-0000-0000-0000-000000000389' > \
    "${temp}/reader/.kobo/version"
printf '%s\n' 'test database' > "${temp}/reader/.kobo/KoboReader.sqlite"
"${project_dir}/scripts/check-device-compatibility.py" \
    "${project_dir}/compatibility.json" "${temp}/reader/.kobo/version" \
    > "${temp}/compatibility-tested.out"
grep -F 'Device tested' "${temp}/compatibility-tested.out" >/dev/null
"${project_dir}/scripts/check-device-compatibility.py" \
    "${project_dir}/tests/fixtures/compatibility-untested.json" \
    "${temp}/reader/.kobo/version" > "${temp}/compatibility-untested.out" \
    2> "${temp}/compatibility-untested.err"
grep -F 'Untested' "${temp}/compatibility-untested.out" >/dev/null
grep -F 'WARNING:' "${temp}/compatibility-untested.err" >/dev/null
BOKOPDS_ALLOW_TEST_ARTIFACTS=1 BOKOPDS_INSTALL_DRY_RUN=1 \
    "${project_dir}/scripts/install-to-reader.sh" "${temp}/bokopds-device.tgz" \
    "${temp}/reader" "${temp}/backups"
test ! -e "${temp}/reader/.kobo/KoboRoot.tgz"

BOKOPDS_ALLOW_TEST_ARTIFACTS=1 \
    "${project_dir}/scripts/install-to-reader.sh" "${temp}/bokopds-device.tgz" \
    "${temp}/reader" "${temp}/backups"
cmp "${temp}/bokopds-device.tgz" "${temp}/reader/.kobo/KoboRoot.tgz"
test -n "$(find "${temp}/backups" -name package.sha256 -print -quit)"
permissions=$(stat -c '%a' "${temp}/backups")
test "${permissions}" = 700

# A hard-killed launcher must leave a lock owned by the still-running reader
# process, preventing a second UI instance. A later launch recovers the stale
# lock after that runtime exits.
launch_app="${temp}/launch-app"
launch_lock="${temp}/launch-lock"
mkdir -p "${launch_app}"
cat > "${launch_app}/koreader.sh" <<'EOF'
#!/bin/sh
echo "$$" >> "${BOKOPDS_APP_DIR}/started-pids"
trap 'exit 0' INT TERM HUP
while :; do sleep 1; done
EOF
chmod +x "${launch_app}/koreader.sh"
BOKOPDS_APP_DIR="${launch_app}" BOKOPDS_LOCK_DIR="${launch_lock}" \
BOKOPDS_DOWNLOAD_DIR="${temp}/downloads" BOKOPDS_LIBRARY_ROOT="${temp}" \
    "${project_dir}/device-runtime/launch.sh" &
launch_supervisor=$!
for _attempt in 1 2 3 4 5; do
    [ -s "${launch_lock}/pid" ] && [ "$(cat "${launch_lock}/pid")" != "${launch_supervisor}" ] && break
    sleep 1
done
launch_runtime=$(cat "${launch_lock}/pid")
kill -0 "${launch_runtime}"
kill -KILL "${launch_supervisor}"
wait "${launch_supervisor}" 2>/dev/null || true
BOKOPDS_APP_DIR="${launch_app}" BOKOPDS_LOCK_DIR="${launch_lock}" \
BOKOPDS_DOWNLOAD_DIR="${temp}/downloads" BOKOPDS_LIBRARY_ROOT="${temp}" \
    "${project_dir}/device-runtime/launch.sh"
test "$(wc -l < "${launch_app}/started-pids")" -eq 1
kill "${launch_runtime}"
for _attempt in 1 2 3 4 5; do
    kill -0 "${launch_runtime}" 2>/dev/null || break
    sleep 1
done
if kill -0 "${launch_runtime}" 2>/dev/null; then
    echo "launcher crash test left its runtime alive after termination" >&2
    exit 1
fi
launch_runtime=""
rm -f "${launch_app}/started-pids"
printf '%s\n' '#!/bin/sh' 'exit 0' > "${launch_app}/koreader.sh"
chmod +x "${launch_app}/koreader.sh"
BOKOPDS_APP_DIR="${launch_app}" BOKOPDS_LOCK_DIR="${launch_lock}" \
BOKOPDS_DOWNLOAD_DIR="${temp}/downloads" BOKOPDS_LIBRARY_ROOT="${temp}" \
    "${project_dir}/device-runtime/launch.sh"
test ! -e "${launch_lock}"

if BOKOPDS_ALLOW_TEST_ARTIFACTS=1 \
    "${project_dir}/scripts/install-to-reader.sh" "${temp}/bokopds-device.tgz" \
    "${temp}/reader" "${temp}/backups"; then
    echo "installer accepted a second pending update" >&2
    exit 1
fi

rm "${temp}/reader/.kobo/KoboRoot.tgz"
touch "${temp}/reader/.adds/bokopds/uninstall"
if BOKOPDS_ALLOW_TEST_ARTIFACTS=1 BOKOPDS_INSTALL_DRY_RUN=1 \
    "${project_dir}/scripts/install-to-reader.sh" "${temp}/bokopds-device.tgz" \
    "${temp}/reader" "${temp}/backups"; then
    echo "installer accepted an update while uninstall was pending" >&2
    exit 1
fi
rm "${temp}/reader/.adds/bokopds/uninstall"
printf '%s\n' 'N000,4.9.77,4.38.21908,4.9.77,4.9.77,000000000389' > \
    "${temp}/reader/.kobo/version"
if BOKOPDS_ALLOW_TEST_ARTIFACTS=1 BOKOPDS_INSTALL_DRY_RUN=1 \
    "${project_dir}/scripts/install-to-reader.sh" "${temp}/bokopds-device.tgz" \
    "${temp}/reader" "${temp}/backups"; then
    echo "installer accepted untested firmware" >&2
    exit 1
fi

"${project_dir}/scripts/prepare-uninstall.sh" "${temp}/reader"
test "$(stat -c '%a' "${temp}/reader/.adds/bokopds/uninstall")" = 600
echo "package-layout-tests: ok"
