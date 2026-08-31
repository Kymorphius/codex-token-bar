#!/bin/zsh
set -euo pipefail

runtime_root="${HOME}/Library/Application Support/Codex Token Bar/rsshub-runtime"
package_json="${runtime_root}/node_modules/rsshub/package.json"
wanted_version="1.0.0-master.8aeb46b"
npm_bin="$(command -v npm || true)"

if [[ -z "${npm_bin}" ]]; then
    print -u2 -r -- "未找到 npm，无法安装本机 RSSHub 组件"
    exit 1
fi

if [[ -f "${package_json}" ]] && /usr/bin/grep -q "\"version\": \"${wanted_version}\"" "${package_json}"; then
    print -r -- "RSSHub 本机组件已安装"
    exit 0
fi

/bin/mkdir -p "${runtime_root}"
cd "${runtime_root}"
if [[ ! -f package.json ]]; then
    "${npm_bin}" init -y >/dev/null
fi
"${npm_bin}" install --omit=dev "rsshub@${wanted_version}"
print -r -- "RSSHub 本机组件已安装：${runtime_root}"
