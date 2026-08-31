#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/Codex Token Bar.app"
info_plist="${project_dir}/Resources/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
output_dmg="${project_dir}/dist/Codex-Token-Bar-${version}.dmg"
volume_name="Codex Token Bar"
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-token-bar-dmg.XXXXXX")"
staging_dir="${work_dir}/staging"
rw_dmg="${work_dir}/installer-rw.dmg"
attached_device=""

cleanup() {
    if [[ -n "${attached_device}" ]]; then
        /usr/bin/hdiutil detach "${attached_device}" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "${work_dir}"
}
trap cleanup EXIT

"${script_dir}/build_app.sh" release >/dev/null

/bin/mkdir -p "${staging_dir}/.background"
/usr/bin/ditto "${app_dir}" "${staging_dir}/Codex Token Bar.app"
/bin/ln -s /Applications "${staging_dir}/Applications"
/usr/bin/swift "${script_dir}/make_dmg_background.swift" \
    "${staging_dir}/.background/background.png"

/usr/bin/hdiutil create \
    -volname "${volume_name}" \
    -srcfolder "${staging_dir}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${rw_dmg}" >/dev/null

attach_output="$(/usr/bin/hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    "${rw_dmg}")"
attached_device="$(print -r -- "${attach_output}" | /usr/bin/awk '/Apple_HFS/ { print $1; exit }')"
if [[ -z "${attached_device}" ]]; then
    print -u2 -r -- "无法识别 DMG 临时挂载设备"
    exit 1
fi

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${volume_name}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {120, 120, 780, 540}
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 96
        set text size of icon view options of container window to 13
        set background picture of icon view options of container window to file ".background:background.png"
        set position of item "Codex Token Bar.app" of container window to {160, 210}
        set position of item "Applications" of container window to {500, 210}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

/usr/bin/hdiutil detach "${attached_device}" >/dev/null
attached_device=""
/usr/bin/hdiutil convert \
    "${rw_dmg}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "${output_dmg}" >/dev/null

print -r -- "${output_dmg}"
