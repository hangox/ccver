#!/bin/zsh
set -e

ROOT="${0:A:h:h}"
for file in "$ROOT"/bin/ccver "$ROOT"/lib/*.zsh "$ROOT"/install.sh; do zsh -n "$file"; done

sandbox=$(mktemp -d)
trap 'trash "$sandbox" 2>/dev/null || command rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache"
export CCVER_EVENTS="$sandbox/events" PATH="$sandbox/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/claude/versions" "$XDG_DATA_HOME/ccver" "$XDG_CACHE_HOME/claude/staging" "$sandbox/bin"
printf '#!/bin/sh\nexit 0\n' > "$XDG_DATA_HOME/claude/versions/1.0.0"
chmod +x "$XDG_DATA_HOME/claude/versions/1.0.0"
ln -s "$XDG_DATA_HOME/claude/versions/1.0.0" "$HOME/.local/bin/claude"
printf '1.0.0\n' > "$XDG_DATA_HOME/ccver/pinned-version" 2>/dev/null || { mkdir -p "$XDG_DATA_HOME/ccver"; printf '1.0.0\n' > "$XDG_DATA_HOME/ccver/pinned-version"; }

cat > "$sandbox/bin/claude" <<'MOCK'
#!/bin/zsh
target="$2"
print "start $target" >> "$CCVER_EVENTS"
mkdir -p "$XDG_CACHE_HOME/claude/staging/$target" "$XDG_DATA_HOME/claude/versions"
file="$XDG_CACHE_HOME/claude/staging/$target/claude"
exec 8>"$file"
printf partial >&8
sleep "${CCVER_MOCK_SLEEP:-0.2}"
ln -sf "$file" "$HOME/.local/bin/claude"
[[ "$target" == 9.9.8 ]] && exit 37
printf '#!/bin/sh\nexit 0\n' > "$XDG_DATA_HOME/claude/versions/$target"
chmod +x "$XDG_DATA_HOME/claude/versions/$target"
print "end $target" >> "$CCVER_EVENTS"
MOCK
chmod +x "$sandbox/bin/claude"

source "$ROOT/lib/config.zsh"
source "$ROOT/lib/versions.zsh"
source "$ROOT/lib/pin.zsh"
source "$ROOT/lib/progress.zsh"
source "$ROOT/lib/installer.zsh"

# 非 TTY 不查询 metadata，installer rc 原样传递。
ccver_manifest_size() { print manifest >> "$CCVER_EVENTS"; return 1; }
set +e
TERM=dumb ccver_install_preserve_default 9.9.8 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 37 ]]
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]
[[ "$(ccver_pinned)" == 1.0.0 ]]
[[ "$(<"$CCVER_EVENTS")" == 'start 9.9.8' ]]

# 真实 staging/<version>/claude 只有被 installer/子孙持有时才可观测。
: > "$CCVER_EVENTS"
mkdir -p "$CCVER_STAGING_DIR/9.9.7"
staging_file="$CCVER_STAGING_DIR/9.9.7/claude"
zsh -c 'exec 8>"$1"; printf abc >&8; sleep 3' hold "$staging_file" & holder=$!
sleep 0.3
observer_test() {
    local REPLY="" REPLY_COUNT=0
    ccver_find_staging_file 9.9.7 "$holder"
    [[ "$REPLY" == "$staging_file" && "$REPLY_COUNT" -eq 1 ]]
}
observer_test
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# 双 target 必须串行持锁，最终默认版本保持不变。
: > "$CCVER_EVENTS"
export CCVER_MOCK_SLEEP=0.5
TERM=dumb ccver_install_preserve_default 9.9.1 >/dev/null 2>&1 & first=$!
TERM=dumb ccver_install_preserve_default 9.9.2 >/dev/null 2>&1 & second=$!
wait "$first"; wait "$second"
[[ "$(readlink "$CCVER_BIN_LINK")" == "$CCVER_VERSIONS_DIR/1.0.0" ]]
[[ "$(command sed -nE '2p' "$CCVER_EVENTS")" == 'end 9.9.1' || "$(command sed -nE '2p' "$CCVER_EVENTS")" == 'end 9.9.2' ]]
[[ "$(command sed -nE '3p' "$CCVER_EVENTS")" == start* ]]

echo "全部测试通过"
