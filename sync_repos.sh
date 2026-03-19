#!/bin/bash
# 自动同步多个仓库的Bash脚本
# 如果仓库不存在就clone，否则pull
# 优先使用gh命令，没有则使用git

repos=(
    "git@github.com:anthropics/codex.git"
    "git@github.com:anthropics/openclaw.git"
    "git@github.com:anthropics/gemini-cli.git"
    "git@github.com:anthropics/opencode.git"
    "git@github.com:anthropics/zeroclaw.git"
    "git@github.com:anthropics/claude-code.git"
)

base_dir="$HOME/coding/agent"

# 检查gh是否可用
if command -v gh &> /dev/null; then
    use_gh=true
    echo "使用 gh 命令"
else
    use_gh=false
    echo "gh 未安装，使用 git 命令"
fi

for repo_url in "${repos[@]}"; do
    # 从URL提取仓库名作为目录名
    repo_name=$(basename "$repo_url" .git)
    repo_path="$base_dir/$repo_name"

    if [ -d "$repo_path" ]; then
        echo ""
        echo "=== 更新 $repo_name ==="
        cd "$repo_path"
        if [ "$use_gh" = true ]; then
            gh repo sync
        else
            git pull
        fi
    else
        echo ""
        echo "=== 克隆 $repo_name ==="
        git clone "$repo_url" "$repo_path"
    fi
done

echo ""
echo "完成!"
