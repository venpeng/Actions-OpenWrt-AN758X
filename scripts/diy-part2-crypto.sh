#!/bin/sh
# ==============================================================================
#  AN758X (Airoha AN7581 / AN7583) 加密加速 —— 可选增强补丁
#  被 diy-part2.sh 用 ". ./scripts/diy-part2-crypto.sh" source 进去。
#
#  ⚠ 父脚本开头是 `set -euo pipefail`，本文件在它的 shell 里跑：任何命令返回
#    非 0 都会让 diy-part2.sh 当场退出、剩下的时区 / os-release 等步骤全不执行。
#    所以可能失败的命令都要放进 if/|| 或包进函数 return 0，末尾显式 return 0。
# ==============================================================================

# 追加顶层 .config 的包开关：先删同名旧行（含 "# X is not set"）再追加。
# 仓库 configs/*.config 里本来就带了 chacha20 / lib-chacha20 等 3 个包，
# 直接 cat >> 会留下重复行（defconfig 虽以最后一行为准，但 diffconfig 输出
# 和人工排查都会被干扰）。
append_pkg() {
  for kv in "$@"; do
    k="${kv%%=*}"
    sed -i "/^${k}=/d; /^# ${k} is not set\$/d" .config
    printf '%s\n' "$kv" >> .config
  done
}

# ---------------------------------------------------------------- 开关默认值
: "${OPT_CRYPTO_ARM64CE:=0}"
: "${OPT_CRYPTO_CHACHA:=0}"
: "${OPT_CRYPTO_EIP93:=0}"

echo "::group::加密加速可选包 (ARM64CE=$OPT_CRYPTO_ARM64CE CHACHA=$OPT_CRYPTO_CHACHA EIP93=$OPT_CRYPTO_EIP93)"

# ------------------------------------------------------------ 探测 SoC / 机型
# AN7581 无 ARMv8 AES 指令，只能走 NEON 位切片；AN7583 有 aes/pmull/sha1/sha2，
# 可以走 Crypto Extensions。
#
# ⚠ 优先级：外部传入的 SOC > SOC_OVERRIDE > 自动探测。
#   你的 workflow 在 "Resolve device profile" 步骤里已经按机型校正过 SOC 并
#   写进 GITHUB_ENV，diy-part2.sh 执行时 $SOC 就是准的。本文件是被 source 的，
#   直接赋值 SOC= 会改写父脚本的同名变量——所以必须先认外部值，不要盲猜。
detect_soc() {
  case "${SOC:-}" in
    an7581|an7583) echo "$SOC"; return ;;
  esac
  if [ -n "${SOC_OVERRIDE:-}" ]; then
    echo "$SOC_OVERRIDE"
    return
  fi
  if [ -f .config ]; then
    # 首选 CONFIG_TARGET_SUBTARGET：唯一且明确，不会被 "is not set" 干扰
    if grep -q '^CONFIG_TARGET_SUBTARGET="an7583"' .config; then
      echo "an7583"; return
    fi
    if grep -q '^CONFIG_TARGET_SUBTARGET="an7581"' .config; then
      echo "an7581"; return
    fi
    # 次选：只认 "=y"，避免匹配到 "# CONFIG_TARGET_airoha_an7583 is not set"
    if grep -q '^CONFIG_TARGET_airoha_an7583=y' .config; then
      echo "an7583"; return
    fi
    if grep -q '^CONFIG_TARGET_airoha_an7581=y' .config; then
      echo "an7581"; return
    fi
    # 机型 profile 兜底：AN7583 目前只有 nokia_xg-040g-mf
    if grep -qi 'DEVICE_nokia_xg-040g-mf' .config; then
      echo "an7583"; return
    fi
  fi
  echo "an7581"
}

SOC="$(detect_soc)"
echo "检测到 SoC: $SOC"

# 顶层 .config 必须已存在（由 Load custom configuration 步骤生成），
# 否则 cat >> 会凭空建出一个只有几行包的残缺 .config，后续 defconfig 把
# 整个机型配置冲掉。
if [ ! -f .config ]; then
  echo "::warning::当前目录没有 .config，跳过可选包追加（cwd=$PWD）"
  echo "::endgroup::"
  return 0 2>/dev/null || exit 0
fi

# --------------------------------------------------- 定位 target 内核 config
kernel_cfg_path() {
  base="target/linux/airoha"
  [ -d "$base" ] || { echo ""; return; }
  # 优先精确匹配子目标目录，再退回任意 an758x 目录
  for d in "$base/$SOC" "$base/an7581" "$base/an7583"; do
    if [ -d "$d" ]; then
      f="$(ls "$d"/config-* 2>/dev/null | head -1)"
      if [ -n "$f" ]; then echo "$f"; return; fi
    fi
  done
  # 兜底：generic 目录
  f="$(ls "$base"/generic/config-* 2>/dev/null | head -1)"
  echo "${f:-}"
}

KCFG="$(kernel_cfg_path)"

# 写入内核 config：先删掉同名旧行（含 "# X is not set"），再追加，避免重复
set_kcfg() {
  file="$1"; shift
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "::warning::找不到 target 内核 config，跳过: $*"
    return
  fi
  for kv in "$@"; do
    k="${kv%%=*}"
    sed -i "/^${k}=/d; /^# ${k} is not set\$/d" "$file"
    printf '%s\n' "$kv" >> "$file"
  done
}

# ============================== ① 内核符号：arm64 汇编实现 ==============================
if [ "$OPT_CRYPTO_ARM64CE" = "1" ]; then
  echo "写入 arm64 汇编加密实现 (SoC=$SOC) -> ${KCFG:-未找到}"

  # 用 for 直接枚举，不用 IFS + set --。
  # 本文件被 source 时 set -- 会把父脚本 diy-part2.sh 的位置参数清空。
  COMMON_KCFG="
CONFIG_ARM64_CRYPTO=y
CONFIG_CRYPTO_SIMD=y
CONFIG_CRYPTO_CRYPTD=y
CONFIG_CRYPTO_AES_ARM64=y
CONFIG_CRYPTO_SHA256_ARM64=y
CONFIG_CRYPTO_SHA512_ARM64=y"

  if [ "$SOC" = "an7583" ]; then
    # AN7583: /proc/cpuinfo 有 aes pmull sha1 sha2，走 Crypto Extensions
    SOC_KCFG="
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_GHASH_ARM64_CE=y
CONFIG_CRYPTO_SHA1_ARM64_CE=y
CONFIG_CRYPTO_SHA2_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64_CE=y"
  else
    # AN7581: 无 AES 指令，走 NEON 位切片（bitsliced NEON 在 A53 上约 22 c/B，
    # 远好于标量 aes-generic）
    SOC_KCFG="
CONFIG_CRYPTO_AES_ARM64_BS=y
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y"
  fi

  if [ -n "$KCFG" ]; then
    for kv in $COMMON_KCFG $SOC_KCFG; do
      set_kcfg "$KCFG" "$kv"
    done
  else
    echo "::warning::OPT_CRYPTO_ARM64CE=1 但未定位到内核 config，已跳过"
  fi
fi

# ============================== ② 可选包：ChaCha20-Poly1305 ==============================
if [ "$OPT_CRYPTO_CHACHA" = "1" ]; then
  echo "追加可选包: ChaCha20-Poly1305"
  # aarch64 上 kmod-crypto-lib-chacha20 会自动带 CONFIG_CRYPTO_CHACHA20_NEON，
  # chacha20poly1305 同理，NEON 版无需手写内核符号。
  append_pkg \
  CONFIG_PACKAGE_kmod-crypto-lib-chacha20=y \
  CONFIG_PACKAGE_kmod-crypto-lib-chacha20poly1305=y \
  CONFIG_PACKAGE_kmod-crypto-chacha20poly1305=y \
  CONFIG_PACKAGE_kmod-crypto-lib-poly1305=y \
  CONFIG_PACKAGE_kmod-crypto-lib-curve25519=y \
  CONFIG_PACKAGE_kmod-crypto-kpp=y \
  CONFIG_PACKAGE_kmod-crypto-ecdh=y \
  CONFIG_PACKAGE_kmod-crypto-gcm=y \
  CONFIG_PACKAGE_kmod-crypto-ccm=y \
  CONFIG_PACKAGE_kmod-crypto-ctr=y \
  CONFIG_PACKAGE_kmod-crypto-cbc=y \
  CONFIG_PACKAGE_kmod-crypto-xts=y \
  CONFIG_PACKAGE_kmod-crypto-seqiv=y \
  CONFIG_PACKAGE_kmod-crypto-echainiv=y
fi

# ============================== ③ 可选包：EIP93 硬件引擎 ==============================
if [ "$OPT_CRYPTO_EIP93" = "1" ]; then
  echo "追加可选包: EIP93 硬件加密引擎"
  # 说明：AN7581 内置 EIP93 (crypto@1e004000, compatible airoha,en7581-eip93)。
  # 但它只在大包上划算：实测 AES 需 ≥512 字节才快过软件，MD5/SHA1/SHA2 全尺寸
  # 都是软件更快。代理类小包场景开着反而更慢，所以默认关。
  append_pkg \
  CONFIG_PACKAGE_kmod-crypto-hw-eip93=y \
  CONFIG_PACKAGE_kmod-crypto-authenc=y \
  CONFIG_PACKAGE_kmod-crypto-des=y \
  CONFIG_PACKAGE_kmod-crypto-md5=y \
  CONFIG_PACKAGE_kmod-crypto-sha1=y \
  CONFIG_PACKAGE_kmod-crypto-sha256=y \
  CONFIG_PACKAGE_kmod-crypto-sha512=y \
  CONFIG_PACKAGE_kmod-crypto-hmac=y \
  CONFIG_PACKAGE_kmod-crypto-manager=y \
  CONFIG_PACKAGE_kmod-crypto-hash=y \
  CONFIG_PACKAGE_kmod-crypto-aead=y \
  CONFIG_PACKAGE_kmod-crypto-null=y \
  CONFIG_PACKAGE_kmod-crypto-rng=y \
  CONFIG_PACKAGE_kmod-random-core=y

  # 内核侧：确保 CONFIG_CRYPTO_HW 打开，否则 kmod 编不出来
  set_kcfg "$KCFG" "CONFIG_CRYPTO_HW=y"
fi

# ============================== ④ 用户态 /dev/crypto 接口（随任一开关开） ==============================
if [ "$OPT_CRYPTO_EIP93" = "1" ] || [ "$OPT_CRYPTO_CHACHA" = "1" ]; then
  append_pkg \
  CONFIG_PACKAGE_kmod-crypto-user=y \
  CONFIG_PACKAGE_kmod-cryptodev=y \
  CONFIG_PACKAGE_libopenssl-devcrypto=y
fi

echo "::endgroup::"

# 正常路径也要显式 return 0：父脚本 set -e 下，末尾若残留上一条命令的
# 非 0 状态会让 diy-part2.sh 当场退出。 sourced 时 return，直接执行时 exit。
return 0 2>/dev/null || exit 0
