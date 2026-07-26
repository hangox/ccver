#!/bin/zsh
set -e
[[ "${CCVER_TEST_TRACE:-0}" == 1 ]] && set -x

ROOT="${0:A:h:h}"
NODE_BIN="$(command -v node)"
for file in "$ROOT"/bin/ccver "$ROOT"/lib/*.zsh "$ROOT"/install.sh; do zsh -n "$file"; done
"$NODE_BIN" --check "$ROOT/lib/downloader.ts"
"$NODE_BIN" --check "$ROOT/tests/http-server.ts"

sandbox=$(mktemp -d)
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true; trash "$sandbox" 2>/dev/null || command rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache"
export CCVER_EVENTS="$sandbox/events" CCVER_NODE_BIN="$NODE_BIN" CCVER_TEST_CODESIGN=pass PATH="$sandbox/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/claude/versions" "$XDG_DATA_HOME/ccver" "$XDG_CACHE_HOME/claude/staging" "$sandbox/bin"
printf '#!/bin/sh\nexit 0\n' > "$XDG_DATA_HOME/claude/versions/1.0.0"
chmod +x "$XDG_DATA_HOME/claude/versions/1.0.0"
ln -s "$XDG_DATA_HOME/claude/versions/1.0.0" "$HOME/.local/bin/claude"
printf '1.0.0\n' > "$XDG_DATA_HOME/ccver/pinned-version"

cat > "$sandbox/bin/claude" <<'MOCK'
#!/bin/zsh
target="$2"
print "official $target" >> "$CCVER_EVENTS"
mkdir -p "$XDG_DATA_HOME/claude/versions"
printf '#!/bin/sh\nexit 0\n' > "$XDG_DATA_HOME/claude/versions/$target"
chmod +x "$XDG_DATA_HOME/claude/versions/$target"
[[ "$target" == 9.9.8 ]] && exit 37
exit 0
MOCK
chmod +x "$sandbox/bin/claude"

cat > "$sandbox/bin/codesign" <<'MOCK'
#!/bin/zsh
if [[ "$1" == --verify ]]; then
    [[ "${CCVER_CODESIGN_FAIL:-0}" == 1 ]] && { print -u2 'invalid signature'; exit 1; }
    exit 0
fi
if [[ "$1" == -d ]]; then
    print -u2 "Identifier=${CCVER_CODESIGN_IDENTIFIER_OUTPUT:-com.anthropic.claude-code}"
    print -u2 "TeamIdentifier=${CCVER_CODESIGN_TEAM_OUTPUT:-Q6L2SF6YDW}"
    exit 0
fi
exit 1
MOCK
chmod +x "$sandbox/bin/codesign"

source "$ROOT/lib/config.zsh"
source "$ROOT/lib/versions.zsh"
source "$ROOT/lib/pin.zsh"
source "$ROOT/lib/progress.zsh"
export CCVER_ROOT="$ROOT"
source "$ROOT/lib/installer.zsh"

# renderer 使用固定宽度进度条，且超出 total 时不伪造百分比。
[[ "$(ccver_progress_bar 0)" == '--------------------' ]]
[[ "$(ccver_progress_bar 50)" == '==========----------' ]]
[[ "$(ccver_progress_bar 100)" == '====================' ]]
[[ "$(ccver_render_progress 5 50 100 10 x)" == *'[==========----------]  50%'* ]]
[[ "$(ccver_render_progress 5 101 100 10 x)" != *'%'* ]]
render_controls="$sandbox/render-controls"
if [[ "${CCVER_TEST_TRACE:-0}" == 1 ]]; then
    set +x
    {
        ccver_progress_begin
        ccver_progress_draw 'line'
        ccver_progress_finish
    } 2> "$render_controls"
    set -x
else
    {
        ccver_progress_begin
        ccver_progress_draw 'line'
        ccver_progress_finish
    } 2> "$render_controls"
fi
[[ "$(od -An -tx1 -v "$render_controls" | tr -d ' \n')" == '1b5b3f32356c0d1b5b324b6c696e650d1b5b324b1b5b3f3235680a' ]]

# 原有 staging observer 同时兼容两种官方布局。
mkdir -p "$CCVER_STAGING_DIR/9.9.1"
staging_file="$CCVER_STAGING_DIR/9.9.1/claude"
zsh -c 'exec 8>"$1"; printf abc >&8; sleep 3' hold "$staging_file" & holder=$!
sleep 0.3
observer_test() {
    local REPLY="" REPLY_COUNT=0
    ccver_find_staging_file 9.9.1 "$holder"
    [[ "$REPLY" == "$staging_file" && "$REPLY_COUNT" -eq 1 ]]
}
observer_test
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

timestamp_dir="$CCVER_STAGING_DIR/9.9.0.4321.987654321"
mkdir -p "$timestamp_dir"
timestamp_file="$timestamp_dir/claude"
zsh -c 'exec 8>"$1"; printf abc >&8; sleep 3' hold "$timestamp_file" & timestamp_holder=$!
sleep 0.3
timestamp_observer_test() {
    local REPLY="" REPLY_COUNT=0
    ccver_find_staging_file 9.9.0 "$timestamp_holder"
    [[ "$REPLY" == "$timestamp_file" && "$REPLY_COUNT" -eq 1 ]]
}
timestamp_observer_test
kill "$timestamp_holder" 2>/dev/null || true
wait "$timestamp_holder" 2>/dev/null || true

# 启动本地 HTTP 服务，测试真实并发 Range、续传和安全失败分类。
port_file="$sandbox/port"
http_events="$sandbox/http-events"
"$NODE_BIN" "$ROOT/tests/http-server.ts" "$port_file" "$http_events" & server_pid=$!
for _ in {1..100}; do [[ -s "$port_file" ]] && break; sleep 0.05; done
[[ -s "$port_file" ]]
export CCVER_RELEASES_URL="http://127.0.0.1:$(<"$port_file")"
export CCVER_DOWNLOADS_DIR="$sandbox/downloads"
export CCVER_ASSEMBLY_DIR="$XDG_DATA_HOME/claude/versions/.ccver-staging"
export CCVER_VERSIONS_DIR="$XDG_DATA_HOME/claude/versions"
export CCVER_VERSION_LOCKS_DIR="$XDG_DATA_HOME/ccver/version-locks"
export CCVER_CHUNK_SIZE=65536 CCVER_DOWNLOAD_WORKERS=4 CCVER_REQUEST_TIMEOUT_MS=5000

# 默认自研路径：并发 Range、size/hash/signature、原子 no-clobber，且不调用官方 fallback。
: > "$CCVER_EVENTS"; : > "$http_events"
TERM=dumb ccver_install_preserve_default 9.9.1 >/dev/null 2>&1
[[ -x "$CCVER_VERSIONS_DIR/9.9.1" ]]
[[ ! -s "$CCVER_EVENTS" ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]
[[ "$(ccver_pinned)" == 1.0.0 ]]
max_active="$(grep -Eo 'max=[0-9]+' "$http_events" | cut -d= -f2 | sort -n | tail -1)"
[[ "$max_active" -ge 2 ]]

# 删除最终版本后重新运行必须复用全部已验证 chunks，不再发送数据 Range。
trash "$CCVER_VERSIONS_DIR/9.9.1"
: > "$http_events"
TERM=dumb ccver_install_preserve_default 9.9.1 >/dev/null 2>&1
[[ -x "$CCVER_VERSIONS_DIR/9.9.1" ]]
[[ "$(grep -Ec 'bytes=[1-9][0-9]*-' "$http_events" || true)" -eq 0 ]]

# Range 不支持属于允许 fallback；官方安装后默认链接恢复。
: > "$CCVER_EVENTS"
set +e
TERM=dumb ccver_install_preserve_default 9.9.2 >"$sandbox/fallback.out" 2>&1
fallback_rc=$?
set -e
[[ "$fallback_rc" -eq 0 ]] || { command perl -ne 'print' "$sandbox/fallback.out" >&2; return "$fallback_rc"; }
[[ "$(<"$CCVER_EVENTS")" == 'official 9.9.2' ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]

# 暂时性 manifest 503 属于允许 fallback。
: > "$CCVER_EVENTS"
TERM=dumb ccver_install_preserve_default 9.9.9 >/dev/null 2>&1
[[ "$(<"$CCVER_EVENTS")" == 'official 9.9.9' ]]

# manifest、Content-Range、ETag、checksum、签名异常必须 fail-closed，禁止官方 fallback。
for version in 9.9.3 9.9.4 9.9.5 9.9.6; do
    : > "$CCVER_EVENTS"
    set +e
    TERM=dumb ccver_install_preserve_default "$version" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 65 ]]
    [[ ! -s "$CCVER_EVENTS" ]]
done

# ETag 漂移路径必须稳定收敛：连续 20 次均返回 65、没有官方 fallback、没有 Node rc13/unsettled await。
for attempt in {1..20}; do
    trash "$CCVER_DOWNLOADS_DIR/9.9.5" 2>/dev/null || true
    : > "$CCVER_EVENTS"
    drift_stderr="$sandbox/etag-drift-$attempt.stderr"
    set +e
    TERM=dumb ccver_install_preserve_default 9.9.5 >/dev/null 2>"$drift_stderr"
    rc=$?
    set -e
    [[ "$rc" -eq 65 ]]
    [[ ! -s "$CCVER_EVENTS" ]]
    ! grep -Eq 'unsettled top-level await|Detected unsettled|exit code 13' "$drift_stderr"
done

: > "$CCVER_EVENTS"
export CCVER_TEST_CODESIGN=fail
set +e
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1
rc=$?
set -e
export CCVER_TEST_CODESIGN=pass
[[ "$rc" -eq 65 && ! -s "$CCVER_EVENTS" ]]

# final 冲突必须返回 73，不能覆盖或 fallback。
printf '冲突内容' > "$CCVER_VERSIONS_DIR/9.9.7"
chmod -x "$CCVER_VERSIONS_DIR/9.9.7"
: > "$CCVER_EVENTS"
set +e
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 73 && ! -s "$CCVER_EVENTS" ]]
[[ "$(<"$CCVER_VERSIONS_DIR/9.9.7")" == '冲突内容' ]]
trash "$CCVER_VERSIONS_DIR/9.9.7"

# use/pin 仍只在安装成功后改变对应状态。
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1
ccver_switch_default 9.9.7 >/dev/null
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/9.9.7" ]]
ccver_pin_only 9.9.7 >/dev/null
[[ "$(ccver_pinned)" == 9.9.7 ]]
ccver_switch_default 1.0.0 >/dev/null
ccver_pin_only 1.0.0 >/dev/null

# 同 target 两进程由 per-version/global lock 串行，官方 fallback 不应被调用。
trash "$CCVER_VERSIONS_DIR/9.9.7"
: > "$CCVER_EVENTS"
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1 & first=$!
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1 & second=$!
wait "$first"; wait "$second"
[[ -x "$CCVER_VERSIONS_DIR/9.9.7" && ! -s "$CCVER_EVENTS" ]]

# 自研下载取消返回 130，不 fallback、不写 final，并保留已验证 chunks。
trash "$CCVER_VERSIONS_DIR/9.9.7"
trash "$CCVER_DOWNLOADS_DIR/9.9.7" 2>/dev/null || true
: > "$CCVER_EVENTS"
CCVER_RELEASES_URL="$CCVER_RELEASES_URL" CCVER_CACHE_HOME="$CCVER_CACHE_HOME" \
CCVER_VERSIONS_DIR="$CCVER_VERSIONS_DIR" CCVER_DOWNLOADS_DIR="$CCVER_DOWNLOADS_DIR" \
CCVER_ASSEMBLY_DIR="$CCVER_ASSEMBLY_DIR" CCVER_CHUNK_SIZE="$CCVER_CHUNK_SIZE" \
CCVER_DOWNLOAD_WORKERS=1 CCVER_REQUEST_TIMEOUT_MS="$CCVER_REQUEST_TIMEOUT_MS" TERM=dumb \
"$NODE_BIN" "$ROOT/lib/downloader.ts" 9.9.7 >/dev/null 2>&1 & cancel_pid=$!
for _ in {1..100}; do
    [[ -n "$(find "$CCVER_DOWNLOADS_DIR/9.9.7" -name 'chunk-*' ! -name '*.tmp.*' -print -quit 2>/dev/null)" ]] && break
    sleep 0.05
done
kill -INT "$cancel_pid"
set +e
wait "$cancel_pid"
rc=$?
set -e
[[ "$rc" -eq 130 ]]
[[ ! -e "$CCVER_VERSIONS_DIR/9.9.7" && ! -s "$CCVER_EVENTS" ]]
[[ -n "$(find "$CCVER_DOWNLOADS_DIR/9.9.7" -name 'chunk-*' ! -name '*.tmp.*' -print -quit 2>/dev/null)" ]]
[[ -z "$(find "$CCVER_DOWNLOADS_DIR/9.9.7" -name '*.tmp.*' -print -quit 2>/dev/null)" ]]

# 官方 fallback 的取消控制器：INT 被忽略时 2 秒后 TERM，完整 wait，返回首次信号 130。
cat > "$sandbox/bin/claude" <<'MOCK_CANCEL'
#!/bin/zsh
trap 'print ignored-int >> "$CCVER_EVENTS"' INT
trap 'print got-term >> "$CCVER_EVENTS"; exit 143' TERM
zsh -c 'trap "" INT; trap "exit 143" TERM; while true; do sleep 0.1; done' &
print "worker=$!" >> "$CCVER_EVENTS"
while true; do sleep 0.1; done
MOCK_CANCEL
chmod +x "$sandbox/bin/claude"
: > "$CCVER_EVENTS"
zsh -f -c 'source "$1/lib/config.zsh"; source "$1/lib/progress.zsh"; source "$1/lib/installer.zsh"; ccver_run_official_install 9.9.8' run "$ROOT" >/dev/null 2>&1 & official_pid=$!
sleep 0.3
kill -INT "$official_pid"
set +e
wait "$official_pid"
rc=$?
set -e
[[ "$rc" -eq 130 ]]
[[ "$(<"$CCVER_EVENTS")" == *got-term* ]]
worker_pid="$(grep '^worker=' "$CCVER_EVENTS" | tail -1 | cut -d= -f2)"
[[ -z "$worker_pid" || ! -e "/proc/$worker_pid" ]]

# 官方失败 rc 原样传递且默认 link/pin 保持。
cat > "$sandbox/bin/claude" <<'MOCK_FAIL'
#!/bin/zsh
exit 37
MOCK_FAIL
chmod +x "$sandbox/bin/claude"
set +e
TERM=dumb ccver_run_official_install 9.9.8 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 37 ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]
[[ "$(ccver_pinned)" == 1.0.0 ]]

echo "全部测试通过"
