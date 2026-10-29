#!/usr/bin/env bash
#
# git-askpass —— 把 GitHub App 安装令牌喂给 git 的凭证助手
#
# 用法（build-ponwrt.yml 里已配好）：
#   install -m 700 scripts/git_askpass.sh "$RUNNER_TEMP/git-askpass"
#   然后导出 GIT_ASKPASS=$RUNNER_TEMP/git-askpass、GIT_TERMINAL_PROMPT=0
#
# 令牌来源（优先文件）：
#   GH_TOKEN_FILE  600 权限的令牌文件路径（令牌不进任何进程的 env）
#   GH_REPO_TOKEN  直接放令牌（App 令牌输出会被自动 add-mask）
#
# ⚠ 不用 url.*.insteadOf：它会把 user:token@ 落盘到 ~/.gitconfig，还会和
#   checkout 注入的 extraheader 抢优先级（本地 .git/config 更高 → 令牌被盖掉
#   → 404）。askpass 只在 git 要认证时才被调用，不写配置、不改 URL。
#   公开仓库 clone 不会触发它。

set -euo pipefail

token_file="${GH_TOKEN_FILE:-}"
token="${GH_REPO_TOKEN:-}"

case "$1" in
    *Username*)
        # GitHub 用令牌认证时用户名固定为 x-access-token（App 安装令牌同 PAT）
        printf '%s\n' 'x-access-token'
        ;;

    *Password*)
        # -s 而不是 -r：空文件会让 git 拿着空密码去认证，报错比没令牌还难懂
        if [ -n "$token_file" ] && [ -s "$token_file" ] && [ -r "$token_file" ]; then
            printf '%s\n' "$(cat "$token_file")"
        elif [ -n "$token" ]; then
            printf '%s\n' "$token"
        else
            echo "git-askpass: 没有可用令牌（GH_TOKEN_FILE 与 GH_REPO_TOKEN 均为空）" >&2
            exit 1
        fi
        ;;

    *)
        # 认不出的提示一律拒绝，避免把令牌交给非预期的远端
        exit 1
        ;;
esac
