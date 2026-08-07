#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 READER_STORAGE_ROOT" >&2
    exit 2
fi

reader_root=$1
application_directory="${reader_root}/.adds/bokopds"
marker="${application_directory}/uninstall"

if [ ! -d "${reader_root}/.kobo" ] || [ ! -d "${application_directory}" ]; then
    echo "BokOPDS was not found on the selected reader storage" >&2
    exit 1
fi

if [ -e "${marker}" ]; then
    echo "uninstall is already pending"
    exit 0
fi

( umask 077 && : > "${marker}" )
sync "${marker}" 2>/dev/null || sync
echo "uninstall staged; safely eject and restart the reader"
echo "downloaded publications are intentionally left in place"
