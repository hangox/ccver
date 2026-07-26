function ccver_list_installed() {
    command ls -1 "$CCVER_VERSIONS_DIR" 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

function ccver_current() {
    basename "$(readlink "$CCVER_BIN_LINK" 2>/dev/null)" 2>/dev/null
}

function ccver_local_latest() { ccver_list_installed | tail -1; }

function ccver_list_remote() {
    command -v npm >/dev/null 2>&1 || { echo "缺少 npm，无法查询远端版本" >&2; return 1; }
    command -v node >/dev/null 2>&1 || { echo "缺少 node，无法解析 npm 返回结果" >&2; return 1; }
    command npm view "$CCVER_NPM_PACKAGE" versions --json 2>/dev/null | command node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  try {
    const versions = JSON.parse(input);
    for (const version of Array.isArray(versions) ? versions : [versions]) {
      if (/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) console.log(version);
    }
  } catch (_) { process.exit(1); }
});
' | sort -V
}

function ccver_remote_latest() { ccver_list_remote | tail -1; }

function ccver_is_semver() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

function ccver_resolve_selector() {
    local selector="$1" resolved
    case "$selector" in
        latest|latest-remote)
            resolved="$(ccver_remote_latest)" || return 1
            [[ -n "$resolved" ]] || { echo "远端最新版本为空" >&2; return 1; }
            ;;
        local-latest|installed-latest)
            resolved="$(ccver_local_latest)"
            [[ -n "$resolved" ]] || { echo "本地尚未安装任何版本" >&2; return 1; }
            ;;
        current)
            resolved="$(ccver_current)"
            [[ -n "$resolved" ]] || { echo "当前默认软链接未设置" >&2; return 1; }
            ;;
        *)
            ccver_is_semver "$selector" || { echo "无效版本号或 selector: $selector" >&2; return 1; }
            resolved="$selector"
            ;;
    esac
    printf '%s' "$resolved"
}
