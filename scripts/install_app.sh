#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
built_app="$(${script_dir}/build_app.sh release | tail -1)"
install_root="${HOME}/Applications"
installed_app="${install_root}/Codex Token Bar.app"

/usr/bin/osascript -e 'tell application id "dev.333.codex-token-bar" to quit' 2>/dev/null || true
for _ in {1..20}; do
    if ! /usr/bin/pgrep -x CodexTokenBar >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

/bin/mkdir -p "${install_root}"
/usr/bin/ditto "${built_app}" "${installed_app}"
/usr/bin/open "${installed_app}"

print -r -- "已安装并启动：${installed_app}"
