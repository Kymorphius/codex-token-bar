#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
configuration="release"
bundle_rsshub=true

for argument in "$@"; do
    case "${argument}" in
        debug|release)
            configuration="${argument}"
            ;;
        --skip-bundled-rsshub)
            bundle_rsshub=false
            ;;
        *)
            print -u2 -r -- "未知参数：${argument}"
            print -u2 -r -- "用法：$0 [debug|release] [--skip-bundled-rsshub]"
            exit 2
            ;;
    esac
done

app_dir="${project_dir}/dist/Codex Token Bar.app"
backup_dir="${project_dir}/dist/.Codex Token Bar.app.backup.$$"

cd "${project_dir}"
/usr/bin/swift build --configuration "${configuration}"
binary_dir="$(/usr/bin/swift build --configuration "${configuration}" --show-bin-path)"

/bin/mkdir -p "${project_dir}/dist"
work_dir="$(/usr/bin/mktemp -d "${project_dir}/dist/.codex-token-bar-app.XXXXXX")"
staged_app="${work_dir}/Codex Token Bar.app"
cleanup() {
    /bin/rm -rf "${work_dir}"
    if [[ -e "${backup_dir}" && ! -e "${app_dir}" ]]; then
        /bin/mv "${backup_dir}" "${app_dir}"
    fi
}
trap cleanup EXIT

/bin/mkdir -p "${staged_app}/Contents/MacOS" "${staged_app}/Contents/Resources"
/usr/bin/ditto "${binary_dir}/CodexTokenBar" "${staged_app}/Contents/MacOS/CodexTokenBar"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${staged_app}/Contents/Info.plist"
/usr/bin/ditto "${project_dir}/Resources/AppIcon.icns" "${staged_app}/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "${project_dir}/Resources/rsshub-runner.mjs" "${staged_app}/Contents/Resources/rsshub-runner.mjs"

if [[ "${bundle_rsshub}" == true ]]; then
    runtime_dir="$("${script_dir}/build_macos_rsshub_runtime.sh" | /usr/bin/tail -1)"
    bundled_runtime="${staged_app}/Contents/Resources/rsshub-runtime"
    /usr/bin/ditto "${runtime_dir}" "${bundled_runtime}"
    /usr/bin/codesign --force --sign - "${bundled_runtime}/node"
fi

/usr/bin/codesign --force --sign - "${staged_app}"

/bin/rm -rf "${backup_dir}"
if [[ -e "${app_dir}" ]]; then /bin/mv "${app_dir}" "${backup_dir}"; fi
/bin/mv "${staged_app}" "${app_dir}"
/bin/rm -rf "${backup_dir}"

print -r -- "${app_dir}"
