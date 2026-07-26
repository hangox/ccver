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

function ccver_process_alive() {
    local pid="$1" state
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(command ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$state" && "$state" != Z* ]]
}

function ccver_group_member_pids() {
    local pgid="$1"
    REPLY_PIDS=("${(@f)$(command ps -axo pid=,pgid= 2>/dev/null | CCVER_TARGET_PGID="$pgid" command perl -ane 'print "$F[0]\n" if $F[1] == $ENV{CCVER_TARGET_PGID}')}")
    REPLY_PIDS=("${(@)REPLY_PIDS:#}")
}

function ccver_group_alive() {
    local pgid="$1" pid
    local -a REPLY_PIDS
    ccver_group_member_pids "$pgid"
    for pid in "${REPLY_PIDS[@]}"; do
        ccver_process_alive "$pid" && return 0
    done
    return 1
}

function ccver_signal_group() {
    local signal="$1" pgid="$2" wrapper_pgid
    wrapper_pgid="$(command ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    [[ "$pgid" == <-> && "$pgid" -gt 1 && "$pgid" != "$wrapper_pgid" ]] || return 1
    kill -"$signal" -- -"$pgid" 2>/dev/null || true
}

function ccver_wait_cancelled_group() {
    local root_pid="$1" pgid="$2" cancel_code="$3" started="$EPOCHSECONDS" escalated=0 killed=0
    while ccver_group_alive "$pgid"; do
        if [[ "$escalated" -eq 0 && "$((EPOCHSECONDS - started))" -ge 2 ]]; then
            escalated=1
            ccver_signal_group TERM "$pgid"
        elif [[ "$killed" -eq 0 && "$((EPOCHSECONDS - started))" -ge 5 ]]; then
            killed=1
            ccver_signal_group KILL "$pgid"
        fi
        sleep 0.1
    done
    wait "$root_pid" 2>/dev/null || true
    return "$cancel_code"
}

function ccver_run_official_install() {
    setopt localtraps localoptions nomonitor
    zmodload zsh/datetime 2>/dev/null || true
    local target="$1" force="${2:-0}" installer_pid installer_pgid cancel_code=0 install_rc
    local -a install_args

    [[ -x /usr/bin/perl ]] || { echo "缺少 /usr/bin/perl，无法安全隔离官方安装器" >&2; return 70; }
    if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
        echo "自研下载不可用，切换官方安装器..." >&2
    fi

    install_args=(install "$target")
    [[ "$force" -eq 1 ]] && install_args+=(--force)
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV' \
        "$(command -v claude)" "${install_args[@]}" &
    installer_pid=$!
    installer_pgid="$installer_pid"
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=130; ccver_progress_finish; ccver_signal_group INT "$installer_pgid"; fi' INT
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=143; ccver_progress_finish; ccver_signal_group TERM "$installer_pgid"; fi' TERM
    trap 'if [[ "$cancel_code" -eq 0 ]]; then cancel_code=129; ccver_progress_finish; ccver_signal_group HUP "$installer_pgid"; fi' HUP

    while ccver_process_alive "$installer_pid"; do
        [[ "$cancel_code" -eq 0 ]] || break
        sleep 0.2
    done
    if [[ "$cancel_code" -ne 0 ]]; then
        ccver_wait_cancelled_group "$installer_pid" "$installer_pgid" "$cancel_code"
        return $?
    fi
    wait "$installer_pid"; install_rc=$?
    trap - INT TERM HUP
    return "$install_rc"
}

function ccver_node_supported() {
    local version major
    [[ -n "$CCVER_NODE_BIN" && -x "$CCVER_NODE_BIN" ]] || return 1
    version="$("$CCVER_NODE_BIN" -p 'process.versions.node' 2>/dev/null)" || return 1
    major="${version%%.*}"
    [[ "$major" == <-> && "$major" -ge 22 ]]
}

function ccver_downloader() {
    local mode="$1" target="$2"
    ccver_node_supported || return 75
    [[ -r "$CCVER_ROOT/lib/downloader.ts" ]] || return 75
    CCVER_RELEASES_URL="$CCVER_RELEASES_URL" \
    CCVER_CACHE_HOME="$CCVER_CACHE_HOME" \
    CCVER_VERSIONS_DIR="$CCVER_VERSIONS_DIR" \
    CCVER_DOWNLOADS_DIR="$CCVER_DOWNLOADS_DIR" \
    CCVER_ASSEMBLY_DIR="$CCVER_ASSEMBLY_DIR" \
    CCVER_DOWNLOAD_WORKERS="$CCVER_DOWNLOAD_WORKERS" \
    CCVER_CHUNK_SIZE="$CCVER_CHUNK_SIZE" \
    CCVER_REQUEST_TIMEOUT_MS="$CCVER_REQUEST_TIMEOUT_MS" \
    command "$CCVER_NODE_BIN" "$CCVER_ROOT/lib/downloader.ts" "$mode" "$target"
}

function ccver_verify_native_identity() {
    local target="$1" file="$CCVER_VERSIONS_DIR/$target" details identifier team_id
    [[ -f "$file" && -x "$file" ]] || { echo "版本 $target 不是可执行普通文件" >&2; return 73; }
    [[ -x /usr/bin/codesign ]] || { echo "缺少系统 codesign，无法验证已安装版本" >&2; return 73; }
    /usr/bin/codesign --verify --strict --verbose=2 "$file" >/dev/null 2>&1 || {
        echo "版本 $target 的代码签名无效" >&2
        return 73
    }
    details="$(/usr/bin/codesign -d --verbose=4 "$file" 2>&1)" || return 73
    identifier="$(printf '%s\n' "$details" | command sed -nE 's/^Identifier=(.*)$/\1/p' | command head -n1)"
    team_id="$(printf '%s\n' "$details" | command sed -nE 's/^TeamIdentifier=(.*)$/\1/p' | command head -n1)"
    [[ "$identifier" == com.anthropic.claude-code && "$team_id" == Q6L2SF6YDW ]] || {
        echo "版本 $target 的签名身份不匹配" >&2
        return 73
    }
}

function ccver_verify_installed() {
    ccver_verify_native_identity "$1"
}

function ccver_verify_release() {
    ccver_downloader --verify-release "$1"
}

function ccver_install_fast() {
    ccver_downloader --install "$1"
}

function ccver_install_target() {
    local target="$1" fast_rc
    REPLY_INSTALL_SOURCE=""
    if ccver_install_fast "$target"; then
        REPLY_INSTALL_SOURCE="fast"
        return 0
    else
        fast_rc=$?
    fi
    [[ "$fast_rc" -eq 75 ]] || return "$fast_rc"
    ccver_run_official_install "$target" || return $?
    REPLY_INSTALL_SOURCE="official"
}

function ccver_installed_is_trusted() {
    local target="$1" verify_rc
    ccver_verify_release "$target"; verify_rc=$?
    [[ "$verify_rc" -eq 0 ]] && return 0
    [[ "$verify_rc" -eq 75 ]] || return "$verify_rc"
    # 无法取得本轮 manifest 时，仅接受固定 Anthropic Developer ID 身份；未知或损坏 final 不得 fallback 覆盖。
    ccver_verify_installed "$target"
}

function ccver_install_preserve_default() {
    local target="$1"
    [[ -n "$target" ]] || { echo "安装目标为空" >&2; return 1; }
    command mkdir -p "${CCVER_LOCK_FILE:h}" "$CCVER_VERSION_LOCKS_DIR" || return 1

    (
        local old install_rc lock_rc install_source version_lock="$CCVER_VERSION_LOCKS_DIR/$target.lock"
        exec 9>"$CCVER_LOCK_FILE" || return 1
        /usr/bin/lockf -s 9; lock_rc=$?
        [[ "$lock_rc" -eq 0 ]] || return "$lock_rc"
        exec 8>"$version_lock" || return 1
        /usr/bin/lockf -s 8; lock_rc=$?
        [[ "$lock_rc" -eq 0 ]] || return "$lock_rc"
        if [[ -e "$CCVER_VERSIONS_DIR/$target" ]]; then
            ccver_installed_is_trusted "$target" || return $?
            echo "已安装 $target"
            return 0
        fi

        old="$(readlink "$CCVER_BIN_LINK" 2>/dev/null)"
        ccver_install_target "$target"; install_rc=$?; install_source="$REPLY_INSTALL_SOURCE"
        ccver_restore_default_link "$old"
        if [[ "$install_rc" -ne 0 ]]; then
            echo "安装失败" >&2
            return "$install_rc"
        fi
        if [[ "$install_source" == fast ]]; then
            ccver_verify_release "$target" || return $?
        else
            ccver_verify_installed "$target" || return $?
        fi
        echo "已安装 $target；默认仍为 ${${old:t}:-未设置}"
    )
}

function ccver_ensure_installed() {
    ccver_install_preserve_default "$1"
}

function ccver_switch_default() {
    local target="$1" verify_rc
    [[ -e "$CCVER_VERSIONS_DIR/$target" ]] || { echo "未安装版本 $target" >&2; return 1; }
    ccver_verify_installed "$target"; verify_rc=$?
    [[ "$verify_rc" -eq 0 ]] || return "$verify_rc"
    command mkdir -p "${CCVER_BIN_LINK:h}" || return 1
    local temporary="$CCVER_BIN_LINK.tmp.$$"
    ln -sf "$CCVER_VERSIONS_DIR/$target" "$temporary" || return 1
    command mv -f "$temporary" "$CCVER_BIN_LINK" || return 1
    echo "默认版本已切换 -> $target"
}
