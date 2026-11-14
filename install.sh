if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ]; then
    bin_dir="$PREFIX/bin"
elif [ -w /usr/local/bin ]; then
    bin_dir="/usr/local/bin"
elif command -v sudo >/dev/null 2>&1; then
    bin_dir="/usr/local/bin"
    need_sudo=1
else
    bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
fi
tmp=$(mktemp 2>/dev/null)
echo "正在下载"
curl -o $tmp https://raw.gitcode.com/nasyt/mcts/raw/main/mcts.sh
if [[ $? -eq 0 ]]; then
    mv $tmp $bin_dir/mcts
    chmod +x $bin_dir/mcts
    echo "安装完成"
else
    echo "下载失败"
fi
