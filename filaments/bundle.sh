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
    echo "Error: jq is not installed or not in PATH. You may need to open a new terminal after setup!"
    exit 1
fi
# ensure we have access to tar (comes built-in with Windows and should be available on all modern Linux...)
if ! command -v tar &> /dev/null; then
    echo "Error: tar is not installed or not in PATH. Please install it and try again." >&2
    exit 1
fi

addToBundle() {
    # printer_vendor key contains a list of objects with a vendor key and a filament_path list.
    # Add it to the list where vendor equals the current vendor folder name.
    # Create one where necessary.
    local structureFile="${1:?must provide structure file}"
    local vendorName="${2:?must provide vendor name}"
    local filamentPath="${3:?must provide filament path}"
    
    if vendorObject="$(jq -e --arg vendor "$vendorName" 'any(.printer_vendor[]; .vendor == $vendor)' "${structureFile}")"; then
        if ! printf '%s' "${vendorObject}" | jq -e --arg path "${filamentPath}" 'any(.filament_path[]; . == $path)'; then
            jq --arg vendor "$vendorName" --arg path "${filamentPath}" \
                '(.printer_vendor[] | select(.vendor == $vendor) .filament_path) += [$path]' \
                "${structureFile}" > "${structureFile}.tmp" || return 1
            mv "${structureFile}.tmp" "${structureFile}"
        fi
    else
        jq --arg vendor "$vendorName" --arg path "${filamentPath}" \
            '.printer_vendor += [{"vendor": $vendor, "filament_path": [$path]}]' \
            "${structureFile}" > "${structureFile}.tmp" || return 1
        mv "${structureFile}.tmp" "${structureFile}"
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
                [ "${presetFile}" != "${baseFile}" ] || continue
                presetName="$(basename "${presetFile}")"
                outputFile="${vendorDir}/${presetName}"
                echo "Combining base file '${baseFile}' with preset file '${presetFile}' into '${outputFile}'"
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

    # finally, create the bundle file, a simple "zip" archive with custom extension:
    tar -cf "${baseDir}/${bundleName}.orca_filament" -C "${bundleDir}" .
done
