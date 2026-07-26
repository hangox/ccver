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

原则：默认使用官方 manifest 与 CDN 进行可恢复并行下载，并严格校验
size、SHA-256 与 Anthropic Developer ID 签名；仅在安全的可恢复故障下
退回 `claude install <target>`，完整性或并发冲突会直接停止。
EOF
}

function ccver_print_remote() {
    local limit="${1:-30}" remote
    [[ "$limit" == <-> && "$limit" -gt 0 ]] || { echo "数量必须是正整数" >&2; return 1; }
    remote="$(ccver_list_remote)" || return 1
    printf '%s\n' "$remote" | tail -n "$limit"
}
