# ccver 路径与外部依赖配置。所有值都允许调用方通过环境变量覆盖。

: "${CCVER_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}}"
: "${CCVER_CACHE_HOME:=${XDG_CACHE_HOME:-$HOME/.cache}}"
: "${CCVER_VERSIONS_DIR:=$CCVER_DATA_HOME/claude/versions}"
: "${CCVER_BIN_LINK:=$HOME/.local/bin/claude}"
: "${CCVER_PIN_FILE:=$CCVER_DATA_HOME/ccver/pinned-version}"
: "${CCVER_LOCK_FILE:=$CCVER_DATA_HOME/ccver/install.lock}"
: "${CCVER_STAGING_DIR:=$CCVER_CACHE_HOME/claude/staging}"
: "${CCVER_NPM_PACKAGE:=@anthropic-ai/claude-code}"
: "${CCVER_RELEASES_URL:=https://downloads.claude.ai/claude-code-releases}"
