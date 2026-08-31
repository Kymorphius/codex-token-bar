#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
configuration="${1:-release}"
app_dir="${project_dir}/dist/Codex Token Bar.app"

cd "${project_dir}"
/usr/bin/swift build --configuration "${configuration}"
binary_dir="$(/usr/bin/swift build --configuration "${configuration}" --show-bin-path)"

if [[ -e "${app_dir}" ]]; then
    /bin/rm -rf "${app_dir}"
fi

/bin/mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
/usr/bin/ditto "${binary_dir}/CodexTokenBar" "${app_dir}/Contents/MacOS/CodexTokenBar"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
/usr/bin/ditto "${project_dir}/Resources/rsshub-runner.mjs" "${app_dir}/Contents/Resources/rsshub-runner.mjs"
/usr/bin/codesign --force --deep --sign - "${app_dir}"

print -r -- "${app_dir}"
