#!/bin/bash
# 自动同步多个仓库的Bash脚本
# 如果仓库不存在就clone，否则pull
# 优先使用gh命令，没有则使用git

failed_clones=()

repos=(
    "https://github.com/openai/codex.git"
    "https://github.com/anomalyco/opencode.git"
    "https://github.com/openclaw/openclaw.git"
    "https://github.com/google-gemini/gemini-cli.git"
    "https://github.com/anthropics/claude-code.git"
    "https://github.com/zeroclaw-labs/zeroclaw.git"
)

base_dir="$(pwd)"

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
        git fetch origin --quiet
        # 获取远程默认分支名
        remote_default=$(git remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/.*: //')
        if [ -n "$remote_default" ]; then
            git checkout --force "$remote_default" 2>/dev/null
            git reset --hard "origin/$remote_default"
            git clean -fdx -e "!/.gitkeep" 2>/dev/null
            if [ "$use_gh" = true ]; then
                gh repo sync -b "$remote_default" --force
            fi
        fi
    else
        echo ""
        echo "=== 克隆 $repo_name ==="
        if ! git clone "$repo_url" "$repo_path" 2>&1; then
            echo "✗ 克隆失败: $repo_url"
            echo "  可能原因:"
            echo "    - 网络连接问题"
            echo "    - 仓库地址错误或仓库不存在"
            echo "    - 没有访问该仓库的权限"
            failed_clones+=("$repo_url")
        else
            echo "✓ 克隆成功: $repo_name"
        fi
    fi
done

echo ""
if [ ${#failed_clones[@]} -eq 0 ]; then
    echo "✓ 所有仓库同步完成!"
else
    echo "✗ 有 ${#failed_clones[@]} 个仓库克隆失败:"
    for repo in "${failed_clones[@]}"; do
        echo "  - $repo"
    done
fi
