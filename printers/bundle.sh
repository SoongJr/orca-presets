#!/usr/bin/env bash

# This script manages printer presets for OrcaSlicer.
# In this version we simply handle bundling into an archive with the correct extension.
#
# This script will accept a directory path as an argument (defaults to working directory).
# Each folder in that directory represents a "bundle" that can be imported (may also specify a bundle directly).
# Each bundle contains a bundle_structure.json file and one or more folders
# defining the printer and associated filaments and process presets.
#
# At the moment, the script will not make any changes to these files and simply create a zip file for each bundle folder
# that can be imported into OrcaSlicer, named after the bundle folder with ".orca_printer" extension.

set -euo pipefail
IFS=$'\n\t'

# parameter handling:
unset bundleDir

opts=$(getopt -o d: -l dir: -n "$(basename "$0")" -- "$@") || exit 1
eval set -- "$opts"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            bundleDir="$2"
            shift 2
            ;;
        --)
            shift
            ;;
        *)
            # if --base-dir was not provided, user the first positional argument as bundleDir:
            if [[ -z "${bundleDir:-}" ]]; then
                bundleDir="$1"
                shift
                continue
            fi
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
    esac
done
## fall backl to current working directory if no dir was provided:
bundleDir="${bundleDir:-$(pwd)}"

# abort if 7z is not available
if ! command -v 7z &> /dev/null; then
    echo "Error: 7z is not installed or not in PATH. Please install 7-Zip or p7zip and ensure 7z command is available in PATH." >&2
    exit 1
fi

# Check if given directory itself is a bundle or _containing_ bundles:
structureFile="${bundleDir}/bundle_structure.json"
if ! [ -f "${structureFile}" ]; then
    # Iterate over subdirectories and process each as a bundle
    declare -i failures=0
    for actualBundleDir in "${bundleDir}"/*/ ; do
        [ -d "${actualBundleDir}" ] || continue
        # Recursively call script for subdirectories, preserving parameters:
        bash "$0" -d "${actualBundleDir}" || failures+=1
    done
    exit $failures
fi


# create the bundle as a zip archive (custom .orca_printer extension)
bundleName="$(basename "${bundleDir}")"
createBundleArchive() {
    local bundleDir="${1:?must provide bundle directory}"
    local bundleName="${2:?must provide bundle name}"
    local outputDir="${3:?must provide output directory}"

    local bundleZip="${outputDir}/${bundleName}.orca_printer"
    printf "Creating bundle archive for '%s'...\n" "${bundleName}"
    rm "${bundleZip}" 2> /dev/null || true
    sleep .2s # prevents nextcloud from complaining about file being used by another process
    7z a -tzip -mx=2 "${bundleZip}" "${bundleDir}/." >/dev/null || { echo "Error: Failed to create zip archive." >&2; return 1; }
}
createBundleArchive "${bundleDir}" "${bundleName}" "$(dirname "$(dirname "${bundleDir}")")" || exit 1

exit 0
