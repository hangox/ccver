#!/bin/zsh
set -e

root="${0:A:h}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/ccver"
bin_home="${CCVER_BIN_HOME:-$HOME/.local/bin}"

command mkdir -p "$data_home" "$bin_home"
command cp -R "$root/bin" "$root/lib" "$data_home/"
chmod +x "$data_home/bin/ccver"
ln -sf "$data_home/bin/ccver" "$bin_home/ccver"

echo "已安装 ccver -> $bin_home/ccver"
