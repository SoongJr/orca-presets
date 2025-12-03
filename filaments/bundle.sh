#!/usr/bin/env bash

# This script manages filament presets for OrcaSlicer.
# Filament presets can inherit settings from _SYSTEM_ presets, but not from other _USER_ presets!
# See https://github.com/OrcaSlicer/OrcaSlicer/issues/9536
# To replicate this feature, this script will implement this inheritence by joining the json files
# when creating the bunlde file to be imported into OrcaSlicer.
#
# This script will accept a directory path as an argument (defaults to working directory).
# Each folder in that directory represents a "bundle" that can be imported (may also specify a bundle directly).
# Each bundle contains a bundle_structure.json file and one or more folders, named for a printer vendor.
# Each of these folders contains json files defining filament presets for printers by this vendor.
#
# So far, this is the normal structure of a filament bundle. We add this functionality:
# Each vendor folder may also contain additional subfolders with exactly one "base.json" file
# and one or more files that will be combined with the base file to create presets in the vendor folder.
# The base.json file contains the settings to be inherited by the other files in the same folder.
# The resulting presets will have the same name as the inheriting file and overwrite any existing file in vendor folder.
#
# After processing all vendor folders, the script will create a zip file for each bundle folder
# that can be imported into OrcaSlicer, named after the bundle folder with ".orca_filament" extension.

set -euo pipefail
IFS=$'\n\t'

# parameter handling:
unset bundleDir
unset keepOutputs

opts=$(getopt -o d:k -l dir:,keep,no-keep -n "$(basename "$0")" -- "$@") || exit 1
eval set -- "$opts"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            bundleDir="$2"
            shift 2
            ;;
        -k|--keep)
            keepOutputs=true
            shift
            ;;
        --no-keep)
            unset keepOutputs
            shift
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
# fall back to current working directory if no dir was provided:
bundleDir="${bundleDir:-$(pwd)}"
# use absolute path for bundleDir:
bundleDir="$(realpath "${bundleDir}")"

# ensure we have access to jq
if ! command -v jq &> /dev/null; then
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "jq not found, attempting to install via apt..."
        sudo apt-get update && sudo apt-get install -y jq
    elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "win32"* ]]; then
        echo "jq not found, attempting to install via winget..."
        winget install -e --id jqlang.jq
    fi
fi
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed or not in PATH. You may need to open a new terminal and/or add the location to PATH after setup!"
    exit 1
fi
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
        bash "$0" -d "${actualBundleDir}" ${keepOutputs:+--keep} || failures+=1
    done
    exit $failures
fi

addToBundleStructure() {
    # printer_vendor key contains a list of objects with a vendor key and a filament_path list.
    # Add it to the list where vendor equals the current vendor folder name.
    # Create one where necessary.
    local structureFile="${1:?must provide structure file}"
    local vendorName="${2:?must provide vendor name}"
    local filamentPath="${3:?must provide filament path}"
    
    if vendorObject="$(jq -e --arg vendor "$vendorName" '.printer_vendor[] | select(.vendor == $vendor)' "${structureFile}" 2> /dev/null)"; then
        if ! printf '%s' "${vendorObject}" | jq -e --arg path "${filamentPath}" 'any(.filament_path[]; . == $path)' &> /dev/null; then
            jq --arg vendor "$vendorName" --arg path "${filamentPath}" --indent 4 \
                '(.printer_vendor[] | select(.vendor == $vendor) .filament_path) += [$path]' \
                "${structureFile}" > "/tmp/bundle_structure.json" || return 1
            mv "/tmp/bundle_structure.json" "${structureFile}"
        fi
    else
        jq --arg vendor "$vendorName" --arg path "${filamentPath}" --indent 4 \
            '.printer_vendor += [{"vendor": $vendor, "filament_path": [$path]}]' \
            "${structureFile}" > "/tmp/bundle_structure.json" || return 1
        mv "/tmp/bundle_structure.json" "${structureFile}"
    fi
}

# Process the given bundle folder
bundleName="$(basename "${bundleDir}")"
declare -a filesToBundle=("${bundleDir}"/bundle_structure.json)
# Process each vendor folder in the bundle
for vendorDir in "${bundleDir}"/*/ ; do
    [ -d "${vendorDir}" ] || continue
    vendorName="$(basename "${vendorDir}")"

    # Process each inheritence folder in the vendor folder
    for inheritDir in "${vendorDir}"*/ ; do
        [ -d "${inheritDir}" ] || continue
        baseFile="${inheritDir}/base.json"
        if [ ! -f "${baseFile}" ]; then
            echo "Warning: No base.json found in ${inheritDir}, skipping." >&2
            continue
        fi

        # Combine base file with each other preset file in the inheritence folder
        for presetFile in "${inheritDir}"*.json; do
            presetName="$(basename "${presetFile}")"
            outputFile="${vendorDir}/${presetName}"
            # skip base.json itself
            [ "${presetName}" != "base.json" ] || continue
            echo "Combining preset file '${presetFile}' with base..."
            # combine content of both files.
            # keys specified by the inheriting file should overwrite those in the base file,
            # EXCEPT for "inherits"! This key should be removed from inheriting side first.
            jq -s --indent 4 '.[0] * (.[1] | del(.inherits))' "${baseFile}" "${presetFile}" > "${outputFile}" || {
                echo "Error combining ${baseFile} and ${presetFile}" >&2
                continue
            }
            # add the generated file to the list of files to be bundled
            filesToBundle+=("${outputFile}")
            # make sure this file is listed in bundle_structure.json:
            addToBundleStructure "${structureFile}" "${vendorName}" "${vendorName}/${presetName}" || {
                echo "Error adding ${outputFile} to bundle_structure.json" >&2
                continue
            }
        done
    done
done

# create the bundle as a zip archive (custom .orca_filament extension)
createBundleArchive() {
    local bundleName="${1:?must provide bundle name}" && shift
    local outputDir="${1:?must provide output directory}" && shift
    local -a bundleFiles=("$@")
    local bundleZip="${outputDir}/${bundleName}.orca_filament"

    printf "Creating bundle archive for '%s'...\n" "${bundleName}"
    rm "${bundleZip}" 2> /dev/null || true
    sleep .2s # prevents nextcloud from complaining about file being used by another process
    7z a -tzip -mx=2 "${bundleZip}" "${bundleFiles[@]}" \
        >/dev/null || { echo "Error: Failed to create zip archive." >&2; return 1; }
}
declare -i failed=0
createBundleArchive "${bundleName}" "$(dirname "$(dirname "${bundleDir}")")" "${filesToBundle[@]}" || failed=1 # don't wuit immediately on errors, clean up outputs anyway


if [ -z "${keepOutputs:-}" ]; then
    # once the preset file is created, clean up the generated files in the bundle folder:
    # for each json file in a subfolder of a vendorDir, remove the file of that name from the vendorDir itself
    # (we do not remove them freom the bundle structure though, that part is not crucial unless a filament is deleted,
    # in which case we expect the one who deletes it to also change the bundle_structure)
    printf "Cleaning up generated preset files in bundle '%s'...\n" "${bundleName}"
    for vendorDir in "${bundleDir}"/*/ ; do
        [ -d "${vendorDir}" ] || continue
        for inheritDir in "${vendorDir}"*/ ; do
            [ -d "${inheritDir}" ] || continue
            for presetFile in "${inheritDir}"*.json; do
                presetName="$(basename "${presetFile}")"
                outputFile="${vendorDir}/${presetName}"
                rm -f "${outputFile}" 2>/dev/null || true
            done
        done
    done
fi

exit $((failed))
