function ccver_restore_default_link() {
    local old="$1"
    if [[ -n "$old" ]]; then
        ln -sf "$old" "$CCVER_BIN_LINK"
    elif [[ -L "$CCVER_BIN_LINK" || -e "$CCVER_BIN_LINK" ]]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$CCVER_BIN_LINK" 2>/dev/null || true
        else
            command mv "$CCVER_BIN_LINK" "$CCVER_BIN_LINK.removed.$EPOCHSECONDS" 2>/dev/null || true
        fi
    fi
}

function ccver_install_preserve_default() {
    local target="$1"
    [[ -n "$target" ]] || { echo "安装目标为空" >&2; return 1; }
    [[ -x "$CCVER_VERSIONS_DIR/$target" ]] && { echo "已安装 $target"; return 0; }
    command mkdir -p "${CCVER_LOCK_FILE:h}" || return 1

    (
        local old install_rc lock_rc
        exec 9>"$CCVER_LOCK_FILE" || return 1
        /usr/bin/lockf -s 9; lock_rc=$?
        [[ "$lock_rc" -eq 0 ]] || return "$lock_rc"
        [[ -x "$CCVER_VERSIONS_DIR/$target" ]] && { echo "已安装 $target"; return 0; }

        old="$(readlink "$CCVER_BIN_LINK" 2>/dev/null)"
        ccver_install_with_progress "$target"; install_rc=$?
        ccver_restore_default_link "$old"
        if [[ "$install_rc" -ne 0 ]]; then
            echo "安装失败" >&2
            return "$install_rc"
        fi
        [[ -x "$CCVER_VERSIONS_DIR/$target" ]] || { echo "安装后未找到版本 $target" >&2; return 1; }
        echo "已安装 $target；默认仍为 ${${old:t}:-未设置}"
    )
}

function ccver_ensure_installed() {
    [[ -x "$CCVER_VERSIONS_DIR/$1" ]] && return 0
    ccver_install_preserve_default "$1"
}

function ccver_switch_default() {
    local target="$1"
    [[ -x "$CCVER_VERSIONS_DIR/$target" ]] || { echo "未安装版本 $target" >&2; return 1; }
    command mkdir -p "${CCVER_BIN_LINK:h}" || return 1
    ln -sf "$CCVER_VERSIONS_DIR/$target" "$CCVER_BIN_LINK"
    echo "默认版本已切换 -> $target"
}
