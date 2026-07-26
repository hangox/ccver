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

function ccver_signal_tree() {
    local signal="$1" root_pid="$2" wrapper_pgid installer_pgid pid
    local -a REPLY_PIDS
    wrapper_pgid="$(command ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    installer_pgid="$(command ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d ' ')"
    if [[ "$installer_pgid" == <-> && "$installer_pgid" -gt 1 && "$installer_pgid" != "$wrapper_pgid" ]]; then
        kill -"$signal" -- -"$installer_pgid" 2>/dev/null || true
        return
    fi
    ccver_process_tree_pids "$root_pid"
    for pid in "${(@Oa)REPLY_PIDS}"; do
        kill -"$signal" "$pid" 2>/dev/null || true
    done
}

function ccver_wait_cancelled_process() {
    local pid="$1" cancel_code="$2" started="$EPOCHSECONDS" escalated=0 killed=0 child alive
    local -a cancel_pids REPLY_PIDS
    ccver_process_tree_pids "$pid"
    cancel_pids=("${REPLY_PIDS[@]}")

    while true; do
        alive=0
        for child in "${cancel_pids[@]}"; do
            if kill -0 "$child" 2>/dev/null; then
                alive=1
                break
            fi
        done
        [[ "$alive" -eq 1 ]] || break

        if [[ "$escalated" -eq 0 && "$((EPOCHSECONDS - started))" -ge 2 ]]; then
            escalated=1
            for child in "${(@Oa)cancel_pids}"; do kill -TERM "$child" 2>/dev/null || true; done
        elif [[ "$killed" -eq 0 && "$((EPOCHSECONDS - started))" -ge 5 ]]; then
            killed=1
            for child in "${(@Oa)cancel_pids}"; do kill -KILL "$child" 2>/dev/null || true; done
        fi
        sleep 0.1
    done
    wait "$pid" 2>/dev/null || true
    return "$cancel_code"
}

function ccver_run_official_install() {
    setopt localtraps
    zmodload zsh/datetime 2>/dev/null || true
    local target="$1" installer_pid cancel_code=0 install_rc

    if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
        echo "自研下载不可用，切换官方安装器..." >&2
    fi
    command claude install "$target" &
    installer_pid=$!
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=130; ccver_progress_finish; ccver_signal_tree INT "$installer_pid"; fi' INT
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=143; ccver_progress_finish; ccver_signal_tree TERM "$installer_pid"; fi' TERM
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=129; ccver_progress_finish; ccver_signal_tree HUP "$installer_pid"; fi' HUP

    while kill -0 "$installer_pid" 2>/dev/null; do
        [[ "$cancel_code" -eq 0 ]] || break
        sleep 0.2
    done
    if [[ "$cancel_code" -ne 0 ]]; then
        ccver_wait_cancelled_process "$installer_pid" "$cancel_code"
        return $?
    fi
    wait "$installer_pid"; install_rc=$?
    trap - INT TERM HUP
    return "$install_rc"
}

function ccver_install_fast() {
    local target="$1"
    [[ -n "$CCVER_NODE_BIN" && -x "$CCVER_NODE_BIN" ]] || return 75
    [[ -r "$CCVER_ROOT/lib/downloader.ts" ]] || return 75
    CCVER_RELEASES_URL="$CCVER_RELEASES_URL" \
    CCVER_CACHE_HOME="$CCVER_CACHE_HOME" \
    CCVER_VERSIONS_DIR="$CCVER_VERSIONS_DIR" \
    CCVER_DOWNLOADS_DIR="$CCVER_DOWNLOADS_DIR" \
    CCVER_ASSEMBLY_DIR="$CCVER_ASSEMBLY_DIR" \
    CCVER_DOWNLOAD_WORKERS="$CCVER_DOWNLOAD_WORKERS" \
    CCVER_CHUNK_SIZE="$CCVER_CHUNK_SIZE" \
    CCVER_REQUEST_TIMEOUT_MS="$CCVER_REQUEST_TIMEOUT_MS" \
    CCVER_TEST_CODESIGN="${CCVER_TEST_CODESIGN:-}" \
    command "$CCVER_NODE_BIN" "$CCVER_ROOT/lib/downloader.ts" "$target"
}

function ccver_install_target() {
    local target="$1" fast_rc
    if ccver_install_fast "$target"; then
        return 0
    else
        fast_rc=$?
    fi
    [[ "$fast_rc" -eq 75 ]] || return "$fast_rc"
    ccver_run_official_install "$target"
}

function ccver_install_preserve_default() {
    local target="$1"
    [[ -n "$target" ]] || { echo "安装目标为空" >&2; return 1; }
    [[ -x "$CCVER_VERSIONS_DIR/$target" ]] && { echo "已安装 $target"; return 0; }
    command mkdir -p "${CCVER_LOCK_FILE:h}" "$CCVER_VERSION_LOCKS_DIR" || return 1

    (
        local old install_rc lock_rc version_lock="$CCVER_VERSION_LOCKS_DIR/$target.lock"
        exec 9>"$CCVER_LOCK_FILE" || return 1
        /usr/bin/lockf -s 9; lock_rc=$?
        [[ "$lock_rc" -eq 0 ]] || return "$lock_rc"
        exec 8>"$version_lock" || return 1
        /usr/bin/lockf -s 8; lock_rc=$?
        [[ "$lock_rc" -eq 0 ]] || return "$lock_rc"
        [[ -x "$CCVER_VERSIONS_DIR/$target" ]] && { echo "已安装 $target"; return 0; }

        old="$(readlink "$CCVER_BIN_LINK" 2>/dev/null)"
        ccver_install_target "$target"; install_rc=$?
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
    local temporary="$CCVER_BIN_LINK.tmp.$$"
    ln -sf "$CCVER_VERSIONS_DIR/$target" "$temporary" || return 1
    command mv -f "$temporary" "$CCVER_BIN_LINK" || return 1
    echo "默认版本已切换 -> $target"
}
