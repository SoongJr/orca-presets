#!/usr/bin/env bash

# This script manages process presets for OrcaSlicer.
# In this version we simply handle bundling into an archive to be imported.
#
# This script will accept a directory path as an argument (defaults to working directory).
# This folder contains a number of json files defining one process preset each.
#
# At the moment, the script will not make any changes to these files and simply create a zip file
# that can be imported into OrcaSlicer, named "Process presets.zip".

set -euo pipefail
IFS=$'\n\t'

# parameter handling:
unset presetsDir

opts=$(getopt -o d: -l dir: -n "$(basename "$0")" -- "$@") || exit 1
eval set -- "$opts"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            presetsDir="$2"
            shift 2
            ;;
        --)
            shift
            ;;
        *)
            # if --dir was not provided, user the first positional argument as presetsDir:
            if [[ -z "${presetsDir:-}" ]]; then
                presetsDir="$1"
                shift
                continue
            fi
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
    esac
done
## fall back to current working directory if no dir was provided:
presetsDir="${presetsDir:-$(pwd)}"

# abort if 7z is not available
if ! command -v 7z &> /dev/null; then
    echo "Error: 7z is not installed or not in PATH. Please install 7-Zip or p7zip and ensure 7z command is available in PATH." >&2
    exit 1
fi


# create the bundle as a zip archive, bundling all json files in presetsDir
printf "Creating Process presets archive...\n"
cd "${presetsDir}" || { echo "Error: Failed to change directory to '${presetsDir}'." >&2; exit 1; }
rm "./Process presets.zip" 2> /dev/null || true
7z a -tzip -mx=2 "./Process presets.zip" "*.json" >/dev/null \
    || { echo "Error: Failed to create zip archive." >&2; exit 1; }

exit 0
