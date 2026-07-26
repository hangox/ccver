# ccver

`ccver` 是 macOS-first、zsh-only 的 Claude Code native 多版本管理器。

它提供版本安装、默认版本切换、独立 pin 和真实下载进度。默认安装路径读取官方 manifest，使用并行 HTTP Range 与可恢复分块缓存下载，随后严格验证文件大小、SHA-256 和 Anthropic Developer ID 签名，并通过同文件系统 staging 原子安装。仅在 Range 不受支持、Node 不可用或纯网络类故障等安全条件下，才退回官方命令 `claude install <target>`；manifest、响应范围、ETag、checksum、签名或最终路径冲突等异常会直接停止，避免用后备安装掩盖完整性问题。交互终端使用单行、每秒刷新的固定宽度进度条，结束或取消时恢复光标并换行；重定向日志不会产生动态控制序列。

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
- `CCVER_DOWNLOADS_DIR`
- `CCVER_ASSEMBLY_DIR`
- `CCVER_VERSION_LOCKS_DIR`
- `CCVER_NODE_BIN`
- `CCVER_DOWNLOAD_WORKERS`
- `CCVER_CHUNK_SIZE`
- `CCVER_REQUEST_TIMEOUT_MS`
- `CCVER_NPM_PACKAGE`
- `CCVER_RELEASES_URL`

默认遵循 XDG data/cache 目录；默认 Claude Code 路径与官方 native 安装布局保持一致。

## 要求

- macOS
- zsh
- 已安装 Claude Code native CLI
- `lockf`、`lsof`、`pgrep`、`realpath`
- 查询远端版本需要 npm/node
- 自研高速安装需要 Node.js 22+；缺失时自动使用官方安装器
- 最终验证需要 macOS `codesign`

## 开发

```zsh
zsh tests/test.zsh
```

## 许可

MIT
