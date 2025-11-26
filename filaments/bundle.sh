#!/usr/bin/env bash

# This script manages filament presets for OrcaSlicer.
# Filament presets can inherit settings from _SYSTEM_ presets, but not from other _USER_ presets!
# See https://github.com/OrcaSlicer/OrcaSlicer/issues/9536
# To replicate this feature, this script will implement this inheritence by joining the json files
# when creating the bunlde file to be imported into OrcaSlicer.
#
# This script will accept a directory path as an argument (defaults to working directory).
# Each folder in that directory represents a "bundle" that can be imported.
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
baseDir="${1:-.}"
cd "${baseDir}"

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

addToBundle() {
    # printer_vendor key contains a list of objects with a vendor key and a filament_path list.
    # Add it to the list where vendor equals the current vendor folder name.
    # Create one where necessary.
    local structureFile="${1:?must provide structure file}"
    local vendorName="${2:?must provide vendor name}"
    local filamentPath="${3:?must provide filament path}"
    
    if vendorObject="$(jq -e --arg vendor "$vendorName" '.printer_vendor[] | select(.vendor == $vendor)' "${structureFile}" 2> /dev/null)"; then
        if ! printf '%s' "${vendorObject}" | jq -e --arg path "${filamentPath}" 'any(.filament_path[]; . == $path)' &> /dev/null; then
            jq --arg vendor "$vendorName" --arg path "${filamentPath}" \
                '(.printer_vendor[] | select(.vendor == $vendor) .filament_path) += [$path]' \
                "${structureFile}" > "/tmp/bundle_structure.json" || return 1
            mv "/tmp/bundle_structure.json" "${structureFile}"
        fi
    else
        jq --arg vendor "$vendorName" --arg path "${filamentPath}" \
            '.printer_vendor += [{"vendor": $vendor, "filament_path": [$path]}]' \
            "${structureFile}" > "/tmp/bundle_structure.json" || return 1
        mv "/tmp/bundle_structure.json" "${structureFile}"
    fi
}


# Process each bundle folder
for bundleDir in */ ; do
    [ -d "${bundleDir}" ] || continue
    bundleName="$(basename "${bundleDir}")"
    structureFile="${bundleDir}/bundle_structure.json"
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
                jq -s '.[0] * (.[1] | del(.inherits))' "${baseFile}" "${presetFile}" > "${outputFile}" || {
                    echo "Error combining ${baseFile} and ${presetFile}" >&2
                    continue
                }
                # make sure this file is listed in bundle_structure.json:
                addToBundle "${structureFile}" "${vendorName}" "${vendorName}/${presetName}" || {
                    echo "Error adding ${outputFile} to bundle_structure.json" >&2
                    continue
                }
            done
        done
    done

    # create the bundle as a zip archive (custom .orca_filament extension)
    rm "${baseDir}/${bundleName}.zip" 2> /dev/null || true
    if command -v zip >/dev/null 2>&1; then
        (cd "${bundleDir}" && zip -r -q "${baseDir}/${bundleName}.zip" .) \
        || { echo "Error: Failed to create zip archive using zip." >&2 ; continue; }
    elif command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
        if command -v pwsh >/dev/null 2>&1; then
            pwsh -NoProfile -Command "Compress-Archive -Path '${bundleDir}*' -DestinationPath '${baseDir}/${bundleName}.zip' -Force" \
            || { echo "Error: Failed to create zip archive using PowerShell Compress-Archive." >&2 ; continue; }
        else
            powershell -NoProfile -Command "Compress-Archive -Path '${bundleDir}\\*' -DestinationPath '${baseDir}\\${bundleName}.zip' -Force" \
            || { echo "Error: Failed to create zip archive using PowerShell Compress-Archive." >&2 ; continue; }
        fi
    else
        echo "Error: neither 'zip' nor PowerShell Compress-Archive is available to create zip files. Please install 'zip' or PowerShell." >&2
        exit 1
    fi
    # at least powershell refuses to create a zip archive with a different extension, so enforce the correct extension now:
    mv "${baseDir}/${bundleName}.zip" "${baseDir}/${bundleName}.orca_filament" \
    || echo "Error: Failed to rename zip archive to .orca_filament extension." >&2

    # once the preset file is created, clean up the generated files in the bundle folder:
    # for each json file in a subfolder of a vendorDir, remove the file of that name from the vendorDir itself
    # (we do not remove them freom the bundle structure though, that part is not crucial unless a filament is deleted,
    # in which case we expect the one who deletes it to also change the bundle_structure)
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
done