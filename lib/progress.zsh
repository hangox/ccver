function ccver_manifest_size() {
    local target="$1" platform manifest
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) platform="darwin-arm64" ;;
        Darwin-x86_64) platform="darwin-x64" ;;
        *) return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || return 1
    command -v node >/dev/null 2>&1 || return 1
    manifest="$(command curl -fsSL --connect-timeout 1 --max-time 1 \
        "$CCVER_RELEASES_URL/$target/manifest.json" 2>/dev/null)" || return 1
    printf '%s' "$manifest" | command node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  try {
    const size = JSON.parse(input).platforms?.[process.argv[1]]?.size;
    if (!Number.isSafeInteger(size) || size <= 0) process.exit(1);
    process.stdout.write(String(size));
  } catch (_) { process.exit(1); }
});
' "$platform"
}

function ccver_human_bytes() {
    local bytes="${1:-0}"
    if [[ "$bytes" -ge 1073741824 ]]; then printf '%.1f GiB' "$((bytes / 1073741824.0))"
    elif [[ "$bytes" -ge 1048576 ]]; then printf '%.1f MiB' "$((bytes / 1048576.0))"
    elif [[ "$bytes" -ge 1024 ]]; then printf '%.1f KiB' "$((bytes / 1024.0))"
    else printf '%d B' "$bytes"; fi
}

function ccver_file_size() {
    [[ -f "$1" ]] || return 1
    command stat -f '%z' "$1" 2>/dev/null || command stat -c '%s' "$1" 2>/dev/null
}

function ccver_process_tree_pids() {
    local current child
    local -a queue children
    local -A seen
    queue=("$1")
    REPLY_PIDS=()
    while [[ ${#queue[@]} -gt 0 ]]; do
        current="${queue[1]}"; queue=("${queue[@]:1}")
        [[ -n "$current" && -z "${seen[$current]}" ]] || continue
        seen[$current]=1; REPLY_PIDS+=("$current")
        children=("${(@f)$(command pgrep -P "$current" 2>/dev/null || true)}")
        for child in "${children[@]}"; do [[ -n "$child" ]] && queue+=("$child"); done
    done
}

function ccver_pid_holds_file() {
    local file_path="$1" canonical_file pid held_path canonical_held
    shift
    command -v lsof >/dev/null 2>&1 || return 1
    canonical_file="$(command realpath "$file_path" 2>/dev/null)" || return 1
    for pid in "$@"; do
        while IFS= read -r held_path; do
            canonical_held="$(command realpath "$held_path" 2>/dev/null)" || continue
            [[ "$canonical_held" == "$canonical_file" ]] && return 0
        done < <(command lsof -a -p "$pid" -Fn -- "$file_path" 2>/dev/null | command sed -nE 's/^n//p')
    done
    return 1
}

function ccver_find_staging_file() {
    local target="$1" installer_pid="$2" candidate
    local -a candidates REPLY_PIDS
    REPLY=""; REPLY_COUNT=0
    [[ -d "$CCVER_STAGING_DIR" ]] || return 1
    ccver_process_tree_pids "$installer_pid"
    candidates=("$CCVER_STAGING_DIR/$target"/*(N.))
    for candidate in "${candidates[@]}"; do
        ccver_pid_holds_file "$candidate" "${REPLY_PIDS[@]}" || continue
        REPLY_COUNT=$((REPLY_COUNT + 1)); REPLY="$candidate"
    done
    [[ "$REPLY_COUNT" -eq 1 && -n "$REPLY" ]]
}

function ccver_render_progress() {
    local elapsed="$1" bytes="$2" total="$3" speed="$4" frame="$5"
    if [[ "$total" -gt 0 && "$bytes" -gt 0 && "$bytes" -le "$total" ]]; then
        printf '%s 下载 %3d%%  %s / %s  %s/s  已等待 %ds' "$frame" "$((bytes * 100 / total))" \
            "$(ccver_human_bytes "$bytes")" "$(ccver_human_bytes "$total")" "$(ccver_human_bytes "$speed")" "$elapsed"
    elif [[ "$bytes" -gt 0 ]]; then
        printf '%s 下载中  已接收 %s  %s/s  已等待 %ds' "$frame" "$(ccver_human_bytes "$bytes")" "$(ccver_human_bytes "$speed")" "$elapsed"
    else
        printf '%s 等待安装器创建下载文件  已等待 %ds' "$frame" "$elapsed"
    fi
}

function ccver_install_with_progress() {
    setopt localtraps
    zmodload zsh/datetime 2>/dev/null || true
    local target="$1" installer_pid install_rc total=0 start now bytes=0 previous_bytes=0 previous_time speed=0 file=""
    local observer_ok=1 percent_ok=1 REPLY="" REPLY_COUNT=0 candidate_bytes frame_index=1 line
    local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    if [[ ! -t 2 || "${TERM:-dumb}" == dumb ]]; then
        echo "开始安装 $target（当前环境不刷新进度）..." >&2
        command claude install "$target"
        return $?
    fi

    command claude install "$target" >/dev/null &
    installer_pid=$!; start=$EPOCHSECONDS; previous_time=$start
    trap 'kill -INT "$installer_pid" 2>/dev/null' INT
    trap 'kill -TERM "$installer_pid" 2>/dev/null' TERM
    trap 'kill -HUP "$installer_pid" 2>/dev/null' HUP
    total="$(ccver_manifest_size "$target" 2>/dev/null)" || total=0

    while kill -0 "$installer_pid" 2>/dev/null; do
        now=$EPOCHSECONDS
        REPLY=""; REPLY_COUNT=0
        if [[ "$observer_ok" -eq 1 ]] && ccver_find_staging_file "$target" "$installer_pid"; then
            [[ "$REPLY_COUNT" -ne 1 || (-n "$file" && "$REPLY" != "$file") ]] && percent_ok=0
            file="$REPLY"
            candidate_bytes="$(ccver_file_size "$file" 2>/dev/null)" || { observer_ok=0; candidate_bytes=0; }
            [[ "$candidate_bytes" -lt "$bytes" || ("$total" -gt 0 && "$candidate_bytes" -gt "$total") ]] && percent_ok=0
            bytes="$candidate_bytes"
        elif [[ "$REPLY_COUNT" -gt 0 || -n "$file" ]]; then
            observer_ok=0; percent_ok=0; file=""; bytes=0; speed=0
        fi
        if [[ "$now" -gt "$previous_time" ]]; then
            speed=$(((bytes - previous_bytes) / (now - previous_time))); [[ "$speed" -lt 0 ]] && speed=0
            previous_bytes=$bytes; previous_time=$now
        fi
        local shown_total="$total"
        [[ "$observer_ok" -eq 0 || "$percent_ok" -eq 0 ]] && shown_total=0
        line="$(ccver_render_progress "$((now - start))" "$bytes" "$shown_total" "$speed" "${frames[$frame_index]}" 2>/dev/null)" || line="安装中"
        printf '\r\033[K%s' "$line" >&2
        frame_index=$((frame_index % ${#frames[@]} + 1)); sleep 0.2
    done
    wait "$installer_pid"; install_rc=$?
    trap - INT TERM HUP
    printf '\r\033[K' >&2
    return "$install_rc"
}
