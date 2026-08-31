#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
wanted_version="1.0.0-master.8aeb46b"
wanted_marker="${wanted_version}/slim-v3"
node_bin="$(command -v node || true)"
npm_bin="$(command -v npm || true)"

if [[ -z "${node_bin}" || -z "${npm_bin}" ]]; then
    print -u2 -r -- "构建内置 RSSHub 需要 Node.js 和 npm"
    exit 1
fi

architecture="$(/usr/bin/arch)"
output_root="${1:-${project_dir}/dist/rsshub-runtime-macos-${architecture}}"
marker_path="${output_root}/.codex-tibo-slim-version"
module_path="${output_root}/node_modules/rsshub/dist-lib/pkg.mjs"
bundled_node="${output_root}/node"

if [[ -f "${marker_path}" && -f "${module_path}" && -x "${bundled_node}" && \
      "$(<"${marker_path}")" == "${wanted_marker}" ]]; then
    print -r -- "${output_root}"
    exit 0
fi

work_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-token-bar-rsshub-build.XXXXXX")"
full_root="${work_root}/full"
slim_root="${work_root}/slim"
trace_path="${work_root}/modules.txt"
trace_output="${work_root}/trace-output.txt"
trace_error="${work_root}/trace-error.txt"
trap '/bin/rm -rf "${work_root}"' EXIT

/bin/mkdir -p "${full_root}"
cd "${full_root}"
"${npm_bin}" init -y >/dev/null
"${npm_bin}" install --omit=dev --no-audit --no-fund "rsshub@${wanted_version}" >/dev/null
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
/usr/bin/ditto "${node_bin}" "${slim_root}/node"
/bin/chmod 755 "${slim_root}/node"
printf '%s\n' "${wanted_marker}" > "${slim_root}/.codex-tibo-slim-version"

replacement="${output_root}.new.$$"
backup="${output_root}.backup.$$"
/bin/rm -rf "${replacement}" "${backup}"
/bin/mkdir -p "${output_root:h}"
/bin/mv "${slim_root}" "${replacement}"
if [[ -d "${output_root}" ]]; then /bin/mv "${output_root}" "${backup}"; fi
/bin/mv "${replacement}" "${output_root}"
/bin/rm -rf "${backup}"

print -r -- "${output_root}"
