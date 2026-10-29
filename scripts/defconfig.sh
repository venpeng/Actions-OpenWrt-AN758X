#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# =============================================================
# defconfig.sh —— make defconfig 的唯一调用口
#
#   要解决的问题：
#     `make defconfig 2>&1 | tail -5` 的退出码取的是 tail 的 0。
#     defconfig 真失败时步骤仍然 success，紧接着的「关键包校验」拿到
#     半展开的 .config，报出来的是
#       ::error::以下关键包在 defconfig 后未启用，检查 feeds 是否完整
#     —— 指向完全错误的方向。而这条流水线为「错误信息指向错误根因」
#     已经修过一次（make download 三次失败不再默默继续）。
#
#   做三件事：
#     1) 完整输出落盘；失败打印尾部 N 行 + ::error:: 并 exit 1
#     2) 成功时只打尾部 5 行（保持日志干净，与原行为一致）
#     3) 把输出里的 `WARNING:` 汇总 —— 那是「包被静默剔除」的直接证据。
#        OpenWrt 树本身就有一些无害的 warning，所以只汇总、不失败。
#
#   用法:
#     bash scripts/defconfig.sh [openwrt_dir]
#
#   环境变量:
#     DEFCONFIG_LOG        日志路径（默认 /tmp/defconfig.log）
#     DEFCONFIG_TAIL       成功时打印行数（默认 5）
#     DEFCONFIG_FAIL_TAIL  失败时打印行数（默认 60）
#     DEFCONFIG_WARN_MAX   最多列出多少条 warning（默认 25）
# =============================================================

set -uo pipefail

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::defconfig.sh: 无法进入 $OW"; exit 1; }

LOG="${DEFCONFIG_LOG:-/tmp/defconfig.log}"
TAIL_N="${DEFCONFIG_TAIL:-5}"
FAIL_TAIL_N="${DEFCONFIG_FAIL_TAIL:-60}"
WARN_MAX="${DEFCONFIG_WARN_MAX:-25}"

echo "===== make defconfig ====="

rc=0
make defconfig >"$LOG" 2>&1 || rc=$?

# ---------------------------------------------------------------
# 失败：把真正的原因留在 CI 日志里，而不是让后面那步去猜
# ---------------------------------------------------------------
if [ "$rc" -ne 0 ]; then
	echo "===== defconfig 失败（退出码 $rc），最后 $FAIL_TAIL_N 行 ====="
	tail -n "$FAIL_TAIL_N" "$LOG"
	echo "::error::make defconfig 失败（退出码 $rc）"
	echo "::error::常见根因，按出现频率排："
	echo "::error::  1) feeds 没 update/install，或 tmp/.config-package.in 生成失败"
	echo "::error::  2) package/custom 下同名包两份（feeds 里已有一份时）"
	echo "::error::  3) 某个 Config.in 语法错（日志里搜 'Kconfig:' 或 'syntax error'）"
	echo "::error::  4) 磁盘满（前面 'Check space usage' 若已告警，先看那条）"
	echo "::error::完整日志：$LOG"
	exit 1
fi

tail -n "$TAIL_N" "$LOG"

# ---------------------------------------------------------------
# warning 汇总
#
#   defconfig 里值得看的只有两类，都是「这个包会被静默剔除」：
#     WARNING: Makefile '...' has a dependency on 'x', which does not exist
#     WARNING: Makefile '...' has a build dependency on 'x', which does not exist
#
#   不能让它 fail —— 上游树本来就带一批无害的（可选包缺 optional 依赖）。
#   但完全不报也不行：这东西正是「config 里写了 =y、编完发现没这个菜单」
#   的第一现场。
# ---------------------------------------------------------------
WARN_TOTAL="$(grep -c '^WARNING:' "$LOG" 2>/dev/null || true)"
WARN_TOTAL="${WARN_TOTAL:-0}"

if [ "$WARN_TOTAL" -gt 0 ]; then
	echo "------------------------------------------"
	echo "defconfig 报告了 $WARN_TOTAL 条 WARNING（相关包可能已被剔除）"

	# 上面 tail 已经打过的行不再重复；只在末尾 N 行之外的补齐
	# （GNU head -n -N = 去掉最后 N 行）
	REST="$(head -n "-$TAIL_N" "$LOG" 2>/dev/null | grep '^WARNING:' | head -n "$WARN_MAX" || true)"
	if [ -n "$REST" ]; then
		printf '%s\n' "$REST" | sed 's/^/  /'
		SHOWN=$(printf '%s\n' "$REST" | wc -l)
		[ "$WARN_TOTAL" -gt "$SHOWN" ] && \
			echo "  …另有 $((WARN_TOTAL - SHOWN)) 条（其中一部分可能已在上方末尾输出里）"
	else
		echo "  全部落在上方末尾 $TAIL_N 行内，向上翻即可"
	fi
	echo "------------------------------------------"
	echo "::warning::defconfig 有 $WARN_TOTAL 条 WARNING，依赖缺失的包会被静默剔除"
else
	echo "✅ defconfig 无 WARNING"
fi

echo "✅ make defconfig 完成"
exit 0
