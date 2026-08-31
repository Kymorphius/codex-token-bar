#!/bin/zsh
set -euo pipefail

runtime_root="${HOME}/Library/Application Support/Codex Token Bar/rsshub-runtime"
package_json="${runtime_root}/node_modules/rsshub/package.json"
wanted_version="1.0.0-master.8aeb46b"
slim_marker="${runtime_root}/.codex-tibo-slim-version"
wanted_marker="${wanted_version}/slim-v3"
npm_bin="$(command -v npm || true)"
node_bin="$(command -v node || true)"
script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"

if [[ -z "${npm_bin}" || -z "${node_bin}" ]]; then
    print -u2 -r -- "未找到 Node.js/npm，无法安装本机 RSSHub 组件"
    exit 1
fi

if [[ -f "${package_json}" && -f "${slim_marker}" && \
      -f "${runtime_root}/node_modules/rsshub/dist-lib/pkg.mjs" ]] && \
   /usr/bin/grep -q "\"version\": \"${wanted_version}\"" "${package_json}" && \
   [[ "$(<"${slim_marker}")" == "${wanted_marker}" ]]; then
    print -r -- "RSSHub 精简组件已安装"
    exit 0
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-bar-rsshub.XXXXXX")"
full_root="${work_root}/full"
slim_root="${work_root}/slim"
trace_path="${work_root}/modules.txt"
trace_output="${work_root}/trace-output.txt"
trace_error="${work_root}/trace-error.txt"
trap '/bin/rm -rf "${work_root}"' EXIT

/bin/mkdir -p "${full_root}"
cd "${full_root}"
"${npm_bin}" init -y >/dev/null
"${npm_bin}" install --omit=dev "rsshub@${wanted_version}"
printf '%s' '{"authToken":"invalid-build-trace-token"}' | \
  CODEX_RSSHUB_TRACE_FILE="${trace_path}" "${node_bin}" \
    --no-warnings \
    --experimental-loader "${script_dir}/rsshub-trace-loader.mjs" \
    "${project_dir}/Resources/rsshub-runner.mjs" \
    "${full_root}/node_modules/rsshub/dist-lib/pkg.mjs" \
    '/twitter/user/thsottiaux/includeReplies=0&includeRts=0&readable=1' \
    >"${trace_output}" 2>"${trace_error}"
if ! /usr/bin/grep -q '^CODEX_RSSHUB_MODULE:' "${trace_path}"; then
    print -u2 -r -- "RSSHub 模块追踪失败："
    /usr/bin/tail -20 "${trace_error}" >&2
    exit 1
fi
"${node_bin}" "${script_dir}/prune_rsshub_runtime.mjs" \
    "${full_root}" "${slim_root}" "${trace_path}"
/bin/cp "${full_root}/package.json" "${slim_root}/"
/bin/cp "${full_root}/package-lock.json" "${slim_root}/"
/bin/cp "${project_dir}/Resources/rsshub-runner.mjs" "${slim_root}/"
printf '%s\n' "${wanted_marker}" > "${slim_root}/.codex-tibo-slim-version"

replacement="${runtime_root}.new.$$"
backup="${runtime_root}.backup.$$"
/bin/rm -rf "${replacement}" "${backup}"
/bin/mkdir -p "$(dirname "${runtime_root}")"
/bin/mv "${slim_root}" "${replacement}"
if [[ -d "${runtime_root}" ]]; then /bin/mv "${runtime_root}" "${backup}"; fi
/bin/mv "${replacement}" "${runtime_root}"
/bin/rm -rf "${backup}"
print -r -- "RSSHub 精简组件已安装：${runtime_root}"
