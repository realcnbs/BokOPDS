#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_dir="${project_dir}/build/reader-shell-emulator"
profile_dir="${BOKOPDS_EMULATOR_PROFILE:-${project_dir}/build/reader-shell-profile}"

if [ ! -x "${runtime_dir}/bokopds.lua" ] || [ "${BOKOPDS_REASSEMBLE:-0}" = "1" ]; then
    "${project_dir}/scripts/assemble-reader-shell.sh" "${runtime_dir}"
fi

mkdir -p "${profile_dir}"
if [ ! -f "${profile_dir}/settings.reader.lua" ]; then
    cp "${project_dir}/reader-shell/emulator/settings.reader.lua" \
        "${profile_dir}/settings.reader.lua"
fi

export BOKOPDS_SHELL=1
export KO_HOME="${profile_dir}"
export SDL_VIDEO_X11_WMCLASS=BokOPDS
export SDL_VIDEO_WAYLAND_WMCLASS=BokOPDS
if [ -n "${BOKOPDS_VIDEO_DRIVER:-}" ]; then
    export SDL_VIDEODRIVER="${BOKOPDS_VIDEO_DRIVER}"
fi

cd "${runtime_dir}"
exec ./bokopds.lua "$@"
