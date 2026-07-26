function ccver_pinned() {
    [[ -r "$CCVER_PIN_FILE" ]] || return 0
    command head -n1 "$CCVER_PIN_FILE" 2>/dev/null | tr -d ' \t\r\n'
}

function ccver_pin_only() {
    local target="$1"
    command mkdir -p "${CCVER_PIN_FILE:h}" || return 1
    printf '%s\n' "$target" > "$CCVER_PIN_FILE"
    echo "已锁定 ccver 版本 -> $target（默认软链接未改动）"
}

function ccver_unpin() {
    if [[ ! -e "$CCVER_PIN_FILE" ]]; then
        echo "当前未锁定版本"
        return 0
    fi
    if command -v trash >/dev/null 2>&1; then
        trash "$CCVER_PIN_FILE" || return 1
    else
        command mv "$CCVER_PIN_FILE" "$CCVER_PIN_FILE.removed.$EPOCHSECONDS" || return 1
    fi
    echo "已清除 ccver 锁定"
}
