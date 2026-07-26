function ccver_print_list() {
    local current latest pinned version marker
    current="$(ccver_current)"; latest="$(ccver_local_latest)"; pinned="$(ccver_pinned)"
    echo "current: ${current:-未设置}"
    echo "latest : ${latest:-未安装}"
    echo "pinned : ${pinned:-未设置}"
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        marker="  "; [[ "$version" == "$current" ]] && marker="* "
        echo "$marker$version"
    done <<< "$(ccver_list_installed)"
}

function ccver_help() {
    cat <<'EOF'
ccver — Claude Code native 多版本管理器

用法：
  ccver ls                         显示本地版本、默认版本与 pin
  ccver remote [数量]              显示 npm 上最近的可用版本
  ccver install <版本|latest>      只安装，不改变默认版本与 pin
  ccver use <版本|latest|local-latest|current>
                                   必要时安装，然后切换默认版本
  ccver pin [版本|latest|local-latest|current]
                                   无参数查看 pin；有参数时必要时安装并锁定
  ccver unpin                      清除 pin

原则：ccver 不下载、校验或安装 Claude Code 二进制；唯一安装器始终是
`claude install <target>`。进度仅旁路观察官方安装器的 staging 文件。
EOF
}

function ccver_print_remote() {
    local limit="${1:-30}" remote
    [[ "$limit" == <-> && "$limit" -gt 0 ]] || { echo "数量必须是正整数" >&2; return 1; }
    remote="$(ccver_list_remote)" || return 1
    printf '%s\n' "$remote" | tail -n "$limit"
}
