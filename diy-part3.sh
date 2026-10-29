#!/usr/bin/env bash
# ================================================================
# diy-part3.sh —— 追加插件（在 diy-part2.sh 之后、make defconfig 之前运行）
# 运行目录：ponwrt 源码根目录（cwd 下必须有 .config）
#
# 为什么不直接改 configs/<机型>.config？
#   configs/<机型>.config 是「基座 diffconfig」，删改它会影响所有复用该
#   配置的构建；把插件追加放在这里，既不动机型配置，又能让每次 CI 都
#   稳定编进同一套插件，刷机后不需要再联网 opkg/apk install。
#
# 本脚本做三件事：
#   1) 把下面 PLUGINS 里的插件写成 CONFIG_PACKAGE_<名>=y；
#   2) 把「Kconfig 不一定会自动 select」的直接依赖补成 =y（DEPS）；
#   3) 写出 .diy-part3-packages 清单，工作流在 defconfig 之后逐项复核，
#      防止包不在 feeds 里时被 make defconfig 静默剔除。
#
# 注意：
#   · 这些包都来自 ponwrt 自带的 feeds（luci / packages / 基座 package/emortal），
#     不需要在 diy-part1.sh 里 clone 第三方仓库；
#   · 菜单里的 Extra packages → autocore-arm，在 ponwrt/ImmortalWrt 的
#     package/emortal/autocore/Makefile 里只产出 autocore 一个包，没有独立的
#     autocore-arm 符号。写 autocore-arm 会被 defconfig 当无效符号剔除，
#     所以这里写 autocore。
# ================================================================
set -euo pipefail

echo "=========================================="
echo "追加插件 (diy-part3.sh)"
echo "=========================================="

if [ ! -f .config ]; then
  echo "::error::diy-part3.sh 未找到 .config（应在 ponwrt 源码根目录运行，且晚于配置加载步骤）"
  exit 1
fi

# ---------------------------------------------------------------
# 生效机型（平时只改这里）
#   一行写一个机型；增删机型就改这个数组：
#     · 删掉某一行  = 该机型不再追加这些插件
#     · 数组清空    = 所有机型都追加
#
#   机型名必须和 build-ponwrt.yml 的 profile 选项一致。
# ---------------------------------------------------------------
ENABLED_PROFILES=(
  nokia_xg-040g-md-ubi
  fiberhome_hg5585f-ct
  fiberhome_hg5585f-cu
)

# 当前构建的机型由 workflow 通过环境变量 PROFILE 传进来；
# 本地手动运行时可以没有 PROFILE，那就默认全部执行。
if [ -n "${PROFILE:-}" ] && [ "${#ENABLED_PROFILES[@]}" -gt 0 ]; then
  PROFILE_MATCHED=false
  for p in "${ENABLED_PROFILES[@]}"; do
    if [ "$p" = "$PROFILE" ]; then
      PROFILE_MATCHED=true
      break
    fi
  done
  if [ "$PROFILE_MATCHED" = false ]; then
    echo "PROFILE=$PROFILE 不在启用列表内，跳过附加插件"
    rm -f .diy-part3-packages
    exit 0
  fi
fi

# ---------------------------------------------------------------
# 1. 用户点名的插件
#    顺序与 LuCI 菜单一致，方便对照。
# ---------------------------------------------------------------
PLUGINS=(
  autocore                    # Extra packages → autocore-arm（系统状态 / 温度）
  automount                   # Extra packages → automount（USB 热插拔自动挂载）
  autosamba                   # Extra packages → autosamba（自动挂载 Samba，需 USB）
  luci-app-autoreboot         # LuCI → Applications → 计划重启
  luci-app-ddns               # LuCI → Applications → 动态域名 DNS
  luci-app-homeproxy          # LuCI → Applications → HomeProxy 代理
  luci-app-ttyd               # LuCI → Applications → ttyd 终端
  luci-app-upnp               # LuCI → Applications → UPnP 端口自动转发
  luci-app-wechatpush         # LuCI → Applications → 微信推送
  luci-app-wol                # LuCI → Applications → WOL 网络唤醒
  ddns-scripts-cloudflare     # Network → IP Addresses and Names → Cloudflare DDNS
)

# ---------------------------------------------------------------
# 2. 直接依赖
#    这些包的 Makefile 里虽然写了 +xxx，但不同分支的 Kconfig 对
#    「select 的依赖再展开」处理并不完全一致；显式写出来最稳。
#    已经被基座 config 打开的项目（kmod-nft-tproxy / kmod-tun /
#    ucode-mod-digest 等）不重复列。
# ---------------------------------------------------------------
DEPS=(
  # automount
  block-mount
  kmod-usb-storage
  kmod-usb-storage-extras
  kmod-usb-storage-uas
  kmod-fs-ext4
  kmod-fs-exfat
  kmod-fs-ntfs
  kmod-fs-vfat
  # autosamba
  luci-app-samba4
  samba4-server
  samba4-libs
  wsdd2
  # ddns
  ddns-scripts
  ddns-scripts-services
  # upnp（firewall4 基座必须用 nftables 变体，避免拉进 iptables）
  miniupnpd-nftables
  # homeproxy
  sing-box
  # ttyd
  ttyd
  # wol
  etherwake
  # wechatpush
  curl
  jq
  bash
  iputils-arping
)

# ---------------------------------------------------------------
# 3. 需要显式关掉的互斥变体
#    firewall4 / nftables 基座只能用 miniupnpd-nftables；如果基座或
#    上游默认把 iptables 变体也打开，两个 provider 同时 =y 会让 Kconfig
#    二选一，行为不可预期。
# ---------------------------------------------------------------
DISABLE=(
  miniupnpd-iptables
)

# ---------------------------------------------------------------
# 写 .config
#   先删掉同符号的旧行（=y / is not set / 被注释掉的 =y），再追加，
#   保证幂等，且不会因为基座里残留的 "# CONFIG_PACKAGE_xxx=y" 注释造成
#   排查困难。
# ---------------------------------------------------------------
CONFIG_LINES=0
INDEX_FILE="tmp/.packageinfo"
[ -f "$INDEX_FILE" ] || echo "::warning::未找到 $INDEX_FILE，跳过包索引预检（由 defconfig 后的复核兜底）"

in_index() {
  [ -f "$INDEX_FILE" ] || return 2
  grep -qx "Package: $1" "$INDEX_FILE"
}

set_pkg() {
  local pkg="$1"
  local sym="CONFIG_PACKAGE_${pkg}"

  sed -i -e "/^${sym}=/d" \
         -e "/^#[[:space:]]*${sym}[[:space:]=]/d" .config
  printf '%s=y\n' "$sym" >> .config
  CONFIG_LINES=$((CONFIG_LINES + 1))

  if [ ! -f "$INDEX_FILE" ]; then
    echo "  + ${pkg}（未预检）"
  elif in_index "$pkg"; then
    echo "  ✅ ${pkg}"
  else
    echo "  ⚠ ${pkg} 不在 ${INDEX_FILE} 里（defconfig 可能会剔除）"
  fi
}

echo "--- 插件 ---"
for p in "${PLUGINS[@]}"; do
  set_pkg "$p"
done

echo "--- 依赖 ---"
for p in "${DEPS[@]}"; do
  set_pkg "$p"
done

echo "--- 互斥项 ---"
for p in "${DISABLE[@]}"; do
  sym="CONFIG_PACKAGE_${p}"
  sed -i -e "/^${sym}=/d" \
         -e "/^#[[:space:]]*${sym}[[:space:]=]/d" .config
  printf '# %s is not set\n' "$sym" >> .config
  echo "  ⛔ ${p}（不启用）"
done

# ---------------------------------------------------------------
# 4. 供 workflow 复核：只要求「用户点名」的插件必须 =y。
#    依赖缺失只 warning；插件缺了则直接让构建失败，避免刷完才发现菜单没有。
# ---------------------------------------------------------------
printf '%s\n' "${PLUGINS[@]}" > .diy-part3-packages

MISSING=""
if [ -f "$INDEX_FILE" ]; then
  for p in "${PLUGINS[@]}"; do
    in_index "$p" || MISSING="$MISSING $p"
  done
fi

if [ -n "$MISSING" ]; then
  echo "::error::以下插件不在 $INDEX_FILE 里，make defconfig 会把 =y 静默剔除:$MISSING"
  echo "        确认 feeds 已 update + install，或检查 diy-part1.sh 是否拉取了对应仓库。"
  echo "        实在不需要就把 diy-part3.sh 里对应行删掉/注释掉。"
  exit 1
fi

echo "------------------------------------------"
echo "已写入 $CONFIG_LINES 行 CONFIG_PACKAGE_*=y"
echo "复核清单: $(pwd)/.diy-part3-packages（$(wc -l < .diy-part3-packages) 个插件）"
echo "🎉 diy-part3.sh 执行完毕"
