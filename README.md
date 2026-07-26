# ccver

`ccver` 是 macOS-first、zsh-only 的 Claude Code native 多版本管理器。

它提供版本安装、默认版本切换、独立 pin 和真实下载进度。`ccver` 不接管下载、校验、重试或安装：唯一安装器始终是官方命令 `claude install <target>`。下载进度仅通过安装器 PID/子孙进程持有的 native staging 文件进行旁路观测；无法可靠观测时自动退化为 spinner。

## 安装

```zsh
git clone https://github.com/hangox/ccver.git
cd ccver
./install.sh
```

确保 `~/.local/bin` 位于 `PATH`，然后运行：

```zsh
ccver help
ccver install latest
ccver use 2.1.220
ccver pin current
```

## 配置

可通过以下环境变量覆盖默认路径：

- `CCVER_DATA_HOME`
- `CCVER_CACHE_HOME`
- `CCVER_VERSIONS_DIR`
- `CCVER_BIN_LINK`
- `CCVER_PIN_FILE`
- `CCVER_LOCK_FILE`
- `CCVER_STAGING_DIR`
- `CCVER_NPM_PACKAGE`
- `CCVER_RELEASES_URL`

默认遵循 XDG data/cache 目录；默认 Claude Code 路径与官方 native 安装布局保持一致。

## 要求

- macOS
- zsh
- 已安装 Claude Code native CLI
- `lockf`、`lsof`、`pgrep`、`realpath`
- 查询远端版本需要 npm/node
- 百分比显示需要 curl/node；缺失时不影响安装

## 开发

```zsh
zsh tests/test.zsh
```

## 许可

MIT
