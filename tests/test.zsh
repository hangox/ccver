#!/bin/zsh
set -e
[[ "${CCVER_TEST_TRACE:-0}" == 1 ]] && set -x

ROOT="${0:A:h:h}"
NODE_BIN="$(command -v node)"
for file in "$ROOT"/bin/ccver "$ROOT"/lib/*.zsh "$ROOT"/install.sh; do zsh -n "$file"; done
"$NODE_BIN" --check "$ROOT/lib/downloader.ts"
CCVER_TEST_MODULE="$ROOT/lib/downloader.ts" "$NODE_BIN" --input-type=module -e '
import { pathToFileURL } from "node:url";
const { Progress, renderProgressLine, terminalCellWidth } = await import(pathToFileURL(process.env.CCVER_TEST_MODULE).href);
const narrow = renderProgressLine("⠙", 18, 44.1 * 1024 ** 2, 245 * 1024 ** 2, 1 * 1024 ** 2, "并行下载", 70);
if (terminalCellWidth(narrow) >= 70) throw new Error(`窄终端进度行溢出: ${terminalCellWidth(narrow)}`);
if (narrow.includes("并行下载")) throw new Error("70 列终端应优先省略阶段文字");
const wide = renderProgressLine("⠙", 18, 44.1 * 1024 ** 2, 245 * 1024 ** 2, 1 * 1024 ** 2, "并行下载", 100);
if (!wide.includes("并行下载")) throw new Error("宽终端应保留阶段文字");
let ttyOutput = "";
const ttyStream = { isTTY: true, columns: 70, write(value) { ttyOutput += value; return true; } };
const dynamic = new Progress(245 * 1024 ** 2, 0, ttyStream);
dynamic.setPhase("并行下载");
dynamic.begin();
dynamic.finish("完成");
if (!ttyOutput.startsWith("\x1b[?25l\r\x1b[2K")) throw new Error("TTY 开始控制序列不完整");
if (!ttyOutput.endsWith("\r\x1b[2K\x1b[?25h完成\n")) throw new Error("TTY 结束控制序列不完整");
if (ttyOutput.slice(0, -1).includes("\n")) throw new Error("TTY 动态帧中出现了换行");
let staticOutput = "";
const staticStream = { isTTY: false, columns: undefined, write(value) { staticOutput += value; return true; } };
const staticProgress = new Progress(100, 0, staticStream);
staticProgress.setPhase("并行下载");
staticProgress.begin();
staticProgress.finish("完成");
if (staticOutput !== "并行下载\n完成\n") throw new Error(`非 TTY 降级输出异常: ${JSON.stringify(staticOutput)}`);
'
"$NODE_BIN" --check "$ROOT/tests/downloader-runner.ts"
"$NODE_BIN" --check "$ROOT/tests/http-server.ts"

sandbox=$(mktemp -d)
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true; trash "$sandbox" 2>/dev/null || command rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache"
export CCVER_EVENTS="$sandbox/events" CCVER_NODE_BIN="$NODE_BIN" CCVER_TEST_SIGNATURE_MODE=pass PATH="$sandbox/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/claude/versions" "$XDG_DATA_HOME/ccver" "$XDG_CACHE_HOME/claude/staging" "$sandbox/bin"
export CCVER_TEST_BINARY="$sandbox/claude-fixture"
"$NODE_BIN" -e 'const fs=require("fs");const data=Buffer.allocUnsafe(512*1024);for(let i=0;i<data.length;i++)data[i]=i%251;fs.writeFileSync(process.argv[1],data)' "$CCVER_TEST_BINARY"
chmod +x "$CCVER_TEST_BINARY"
command cp "$CCVER_TEST_BINARY" "$XDG_DATA_HOME/claude/versions/1.0.0"
chmod +x "$XDG_DATA_HOME/claude/versions/1.0.0"
ln -s "$XDG_DATA_HOME/claude/versions/1.0.0" "$HOME/.local/bin/claude"
printf '1.0.0\n' > "$XDG_DATA_HOME/ccver/pinned-version"

cat > "$sandbox/bin/claude" <<'MOCK'
#!/bin/zsh
target="$2"
print "official $target" >> "$CCVER_EVENTS"
mkdir -p "$XDG_DATA_HOME/claude/versions"
command cp "$CCVER_TEST_BINARY" "$XDG_DATA_HOME/claude/versions/$target"
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
function ccver_downloader() {
    local mode="$1" target="$2"
    ccver_node_supported || return 75
    CCVER_RELEASES_URL="$CCVER_RELEASES_URL" CCVER_CACHE_HOME="$CCVER_CACHE_HOME" \
    CCVER_VERSIONS_DIR="$CCVER_VERSIONS_DIR" CCVER_DOWNLOADS_DIR="$CCVER_DOWNLOADS_DIR" \
    CCVER_ASSEMBLY_DIR="$CCVER_ASSEMBLY_DIR" CCVER_DOWNLOAD_WORKERS="$CCVER_DOWNLOAD_WORKERS" \
    CCVER_CHUNK_SIZE="$CCVER_CHUNK_SIZE" CCVER_REQUEST_TIMEOUT_MS="$CCVER_REQUEST_TIMEOUT_MS" \
    "$CCVER_NODE_BIN" "$ROOT/tests/downloader-runner.ts" "$mode" "$target"
}
function ccver_verify_native_identity() {
    local target="$1"
    [[ -f "$CCVER_VERSIONS_DIR/$target" && -x "$CCVER_VERSIONS_DIR/$target" ]] || return 73
    [[ "$CCVER_TEST_SIGNATURE_MODE" == pass ]] || return 73
}

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
for version in 9.9.3 9.9.4 9.9.5 9.9.6 9.9.10; do
    : > "$CCVER_EVENTS"
    set +e
    TERM=dumb ccver_install_preserve_default "$version" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 65 ]]
    [[ ! -s "$CCVER_EVENTS" ]]
done

# ETag 漂移路径必须稳定收敛：连续 20 次均返回 65、没有官方 fallback、没有 Node rc13/unsettled await。
for workers in {1..8}; do
    for attempt in {1..20}; do
        trash "$CCVER_DOWNLOADS_DIR/9.9.5" 2>/dev/null || true
        : > "$CCVER_EVENTS"
        drift_stderr="$sandbox/etag-drift-$workers-$attempt.stderr"
        set +e
        CCVER_DOWNLOAD_WORKERS="$workers" TERM=dumb ccver_install_preserve_default 9.9.5 >/dev/null 2>"$drift_stderr"
        rc=$?
        set -e
        [[ "$rc" -eq 65 ]]
        [[ ! -s "$CCVER_EVENTS" ]]
        ! grep -Eq 'unsettled top-level await|Detected unsettled|exit code 13' "$drift_stderr"
    done
done

# 已安装的未知/篡改 final 不能靠 -x 早退，也不能被 use/pin 激活。
printf '伪造二进制' > "$CCVER_VERSIONS_DIR/9.8.1"
chmod +x "$CCVER_VERSIONS_DIR/9.8.1"
: > "$CCVER_EVENTS"
set +e
TERM=dumb ccver_install_preserve_default 9.8.1 >/dev/null 2>&1
install_untrusted_rc=$?
CCVER_TEST_SIGNATURE_MODE=fail ccver_switch_default 9.8.1 >/dev/null 2>&1
use_untrusted_rc=$?
set -e
[[ "$install_untrusted_rc" -eq 73 && "$use_untrusted_rc" -eq 73 && ! -s "$CCVER_EVENTS" ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]

# Node 18/20 不运行 TypeScript downloader，明确返回 75，由上层走允许的官方 fallback。
real_node_bin="$CCVER_NODE_BIN"
cat > "$sandbox/bin/node20" <<'MOCK_NODE20'
#!/bin/zsh
[[ "$1" == -p ]] && { print 20.19.0; exit 0; }
exit 99
MOCK_NODE20
chmod +x "$sandbox/bin/node20"
CCVER_NODE_BIN="$sandbox/bin/node20"
set +e
ccver_install_fast 9.8.2 >/dev/null 2>&1
node20_fast_rc=$?
set -e
[[ "$node20_fast_rc" -eq 75 ]]
: > "$CCVER_EVENTS"
TERM=dumb ccver_install_target 9.8.2 >/dev/null 2>&1
[[ "$(<"$CCVER_EVENTS")" == 'official 9.8.2' ]]
CCVER_NODE_BIN="$real_node_bin"

: > "$CCVER_EVENTS"
export CCVER_TEST_SIGNATURE_MODE=fail
set +e
TERM=dumb ccver_install_preserve_default 9.9.7 >/dev/null 2>&1
rc=$?
set -e
export CCVER_TEST_SIGNATURE_MODE=pass
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
[[ -z "$worker_pid" ]] || ! kill -0 "$worker_pid" 2>/dev/null

# root installer 自行成功退出但留下忽略所有普通信号的孙进程时，也必须清空 PGID 后返回 root rc。
cat > "$sandbox/bin/claude" <<'MOCK_ROOT_EXIT'
#!/bin/zsh
zsh -c 'trap "" INT TERM HUP; while true; do sleep 0.1; done' &
print "root-exit-worker=$!" >> "$CCVER_EVENTS"
exit 0
MOCK_ROOT_EXIT
chmod +x "$sandbox/bin/claude"
: > "$CCVER_EVENTS"
TERM=dumb ccver_run_official_install 9.9.8 >/dev/null 2>&1
[[ "$?" -eq 0 ]]
root_exit_worker="$(grep '^root-exit-worker=' "$CCVER_EVENTS" | tail -1 | cut -d= -f2)"
[[ -n "$root_exit_worker" ]] || return 1
! kill -0 "$root_exit_worker" 2>/dev/null

# manifest 不可用时，即使 final 具有可信签名身份，也不能冒充任意目标版本。
command cp "$CCVER_TEST_BINARY" "$CCVER_VERSIONS_DIR/9.9.9"
chmod +x "$CCVER_VERSIONS_DIR/9.9.9"
old_link="$(readlink "$CCVER_BIN_LINK")"
old_pin="$(ccver_pinned)"
: > "$CCVER_EVENTS"
set +e
TERM=dumb ccver_install_preserve_default 9.9.9 >/dev/null 2>&1
masked_install_rc=$?
ccver_switch_default 9.9.9 >/dev/null 2>&1
masked_use_rc=$?
ccver_installed_is_trusted 9.9.9 >/dev/null 2>&1
masked_pin_rc=$?
set -e
[[ "$masked_install_rc" -eq 73 && "$masked_use_rc" -eq 73 && "$masked_pin_rc" -eq 73 ]]
[[ ! -s "$CCVER_EVENTS" ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$old_link" && "$(ccver_pinned)" == "$old_pin" ]]

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
