#!/bin/bash
# SPDX-License-Identifier: MIT
#
# host 侧 go-bootstrap / golang / rustc —— 真编译，然后把安装结果打包缓存。
#
# 与「复用 runner 预装的 go / rustup」那条路的区别：
#   那条路省时间但有版本耦合（feed pin 的 rustc 与 runner stable 不一致时炸包）；
#   本脚本是老老实实跑 make <pkg>/host/compile，编出的就是 feed 指定的版本，
#   再把 staging_dir 里的安装结果打包进缓存（actions/cache + Release 双通道，
#   与项目已有的工具链缓存同一套机制）。
#
# 为什么缓存 staging 而不是 build_dir：
#   build_dir/host/rust-<ver> 编完动辄 5~10 GB，GitHub 单条缓存上限 10 GB、
#   仓库总配额 10 GB，存不下。而 make 判断要不要重编看的是
#   staging_dir/host/stamp/.<pkg>_installed 这一组 stamp，不是 build_dir 在不在。
#   所以只打包「stamp + 装进 staging_dir/host 的二进制与库」，build_dir 不要。
#   万一哪次真被判成要重编，源码包还在 dl 缓存里，会自动重编，不会出错。
#
# 子命令（都在源码树根目录执行）：
#   key     算缓存 key，写 HOST_CACHE_KEY / HOST_CACHE_PREFIX / HAS_GO / HAS_RUST 到 GITHUB_OUTPUT
#   build   真编译 host 侧 go(-bootstrap) / rust
#   pack    把 host 产物打成 <KEY>.tzst 放进 $HOST_CACHE_DIR
#   unpack  把 <KEY>.tzst 解回源码树，并 touch stamp 让 make 认定已装
#   status  打印 host go / rustc 版本到 build-reports
#
# 环境变量：
#   HOST_CACHE_DIR        缓存目录（放 tzst），默认 /workdir/hosttool-cache
#   HOST_INCLUDE_BUILDDIR true 时连 build_dir/host 一起打包（默认 false，太大）
#   JOBS                  并发数，默认 nproc

set -uo pipefail

SUBCMD="${1:-status}"
OPENWRT_DIR="${2:-$PWD}"

cd "$OPENWRT_DIR" || { echo "::error::进不去 $OPENWRT_DIR" >&2; exit 1; }

HOST_CACHE_DIR="${HOST_CACHE_DIR:-/workdir/hosttool-cache}"
HOST_INCLUDE_BUILDDIR="${HOST_INCLUDE_BUILDDIR:-false}"
JOBS="${JOBS:-$(nproc)}"
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"

mkdir -p "$HOST_CACHE_DIR" "$REPORT_DIR"

# ---------------------------------------------------------------
# 包探测：feed 装好后符号链接在 package/feeds/<feed>/<pkg>
# ---------------------------------------------------------------
probe_pkg() {  # $1=包名 → 输出 package/ 下的相对路径
  local rel
  rel=$(ls -d package/feeds/*/"$1" 2>/dev/null | head -1)
  [ -n "$rel" ] && printf '%s' "${rel#package/}"
}

pkg_version_mk() {  # $1=Makefile 路径 → GO_VERSION 优先，其次 PKG_VERSION
  [ -f "$1" ] || return 0
  sed -n 's/^GO_VERSION:=[[:space:]]*//p' "$1" 2>/dev/null | head -1 | tr -d '"'
}

# ---------------------------------------------------------------
# 让 make 自己展开变量。
#
#   踩过的坑：golang 的 Makefile 里写的是
#     GO_VERSION:=$(GO_DEFAULT_VERSION)
#   直接 sed 取出来是字面量 "$(GO_DEFAULT_VERSION)"；它原样进了缓存 key，
#   再被 workflow 塞回 shell（KEY="...-go$(GO_DEFAULT_VERSION)-..."），
#   bash 当场当成命令替换执行 → GO_DEFAULT_VERSION: command not found。
#
#   所以：先让 make 展开，取不到再退回 sed 字面量，最后由 sanitize 兜底。
# ---------------------------------------------------------------
make_var() {  # $1=Makefile 路径 $2=变量名
  local mk="$1" var="$2" tmp
  [ -f "$mk" ] || return 0
  tmp=$(mktemp)
  # ⚠ 两个讲究：
  #   1) 配方行必须以真实 TAB 开头，所以整段用 cat heredoc 写，
  #      不用 printf（printf 会把 \n 解释成真换行，把配方行劈成两截）；
  #   2) $(VAR) 外面套单引号：make 展开后交给 shell 打印时，
  #      单引号能挡住值里的反引号 / $() 被 shell 再执行一次
  #      （实测过：写成 echo "$(VAR)" 的话，值里的 `cmd` 会被真跑）。
  cat > "$tmp" <<MAKE
include $mk
ci-print:
	@printf '%s\n' '\$($var)'
MAKE
  make --no-print-directory -s -f "$tmp" TOPDIR="$PWD" ci-print 2>/dev/null | head -1
  rm -f "$tmp"
}

# key 只接受 [A-Za-z0-9._-]，其余一律换成下划线。
# 这是最后一道保险：不管上游 Makefile 写出什么花样（含 $() 、反引号、
# 空格、引号），都不会变成 shell 语法被 workflow 里的 KEY="..." 执行。
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# GO_REL / RUST_REL 是相对 package/ 的路径（make target 用）；
# 读版本与算 hash 要的是绝对路径，两者别混用。
GO_REL=$(probe_pkg golang)
RUST_REL=$(probe_pkg rust)
GO_BOOT_REL=$(probe_pkg golang-bootstrap)

# 包还没 install 到 package/feeds 时，退回 feed 源码里的 Makefile
FEED_GO_MK=$(find feeds -maxdepth 5 -type f -path "*lang/golang/golang/Makefile" 2>/dev/null | head -1)
FEED_RUST_MK=$(find feeds -maxdepth 5 -type f -path "*lang/rust/Makefile" 2>/dev/null | head -1)

GO_MK="${GO_REL:+package/$GO_REL/Makefile}"
RUST_MK="${RUST_REL:+package/$RUST_REL/Makefile}"
[ -n "$GO_MK" ] || GO_MK="$FEED_GO_MK"
[ -n "$RUST_MK" ] || RUST_MK="$FEED_RUST_MK"

# 先让 make 展开（能解析 GO_VERSION:=$(GO_DEFAULT_VERSION) 这类间接定义），
# 展开不出来（Makefile 顶部 include 一堆 rules.mk 时常见）再退回 sed 字面量。
GO_VER=$(make_var "$GO_MK" GO_VERSION)
RUST_VER=$(make_var "$RUST_MK" PKG_VERSION)
[ -n "$GO_VER" ] || GO_VER=$(pkg_version_mk "$GO_MK")
[ -n "$RUST_VER" ] || RUST_VER=$(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' "$RUST_MK" 2>/dev/null | head -1 | tr -d '"')

# 展开出来还是含 $() 的（说明 make 也没解析出来）→ 不硬猜，标 unknown。
# 版本只影响 key 的可读部分，Makefile 的 md5 已经在 hash 里，
# 版本真变了 key 照样会变，不会复用错缓存。
case "$GO_VER"   in *'$('*|'' ) GO_VER=unknown   ;; esac
case "$RUST_VER" in *'$('*|'' ) RUST_VER=unknown ;; esac

# ★ 强制白名单：这是防「$(...) 被 workflow 的 KEY="..." 当命令执行」的最后一道
GO_VER=$(sanitize "$GO_VER")
RUST_VER=$(sanitize "$RUST_VER")

HAS_GO=$([ -n "$GO_REL" ] && echo true || echo false)
HAS_RUST=$([ -n "$RUST_REL" ] && echo true || echo false)

out() { # 同时写 GITHUB_OUTPUT（CI 里）和 stdout
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------
# host 产物的安放位置有三处，不是一个：
#   staging_dir/host              —— 普通 host 包（tools/ 那类：gcc、cmake…）
#   staging_dir/hostpkg           —— HostBuild 且不依赖 target 的包
#                                    实测：golang / golang-bootstrap 在这里
#                                    （构建树 build_dir/hostpkg/go-<ver>）
#   staging_dir/target-*/host     —— HostBuild 但绑定 target 的包
#                                    实测：rust 在这里（configure 的 --prefix
#                                    就是 staging_dir/target-aarch64.../host，
#                                    因为它要 --target=aarch64-unknown-linux-musl
#                                    并 link 到 musl-root）
#
#   只盯着 staging_dir/host 的话，会出现「编了两小时，最后
#   『没有任何 host 产物可打包』」—— 时间全白花，下次还得重编。
#   所以这里三处全扫，哪个存在收哪个。
# ---------------------------------------------------------------
host_stage_dirs() {
  local d
  for d in staging_dir/host staging_dir/hostpkg staging_dir/target-*/host; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# ---------------------------------------------------------------
# 按需判断：本次机型到底要不要 golang / rust
#
#   之前是「包在 package/feeds 里就编」，结果：
#     - HM2004-DU 的机型配置里没有任何 Go 包，却照样跑了一遍
#       golang bootstrap（go1.4→1.17→1.20→1.22→1.24 五段自举，40~70 分钟）；
#     - HAS_PAT=false 时私有仓库拉不下来，h3c-fttr-tools（唯一的 Rust 包）
#       根本不在树里，rustc 也照样编了一遍。
#
#   判据：包 Makefile 里 include 了 golang-package.mk / rust-package.mk，
#   且 .config 里 CONFIG_PACKAGE_<包名>=y。两个条件都满足才算需要。
# ---------------------------------------------------------------
pkg_selected() { # $1=包名
  grep -qE "^CONFIG_PACKAGE_${1}=y$" .config 2>/dev/null
}

need_stack() { # $1=golang-package.mk|rust-package.mk
  local mk name
  for mk in $(grep -Rl --include=Makefile -- "$1" package/ 2>/dev/null); do
    name=$(basename "$(dirname "$mk")")
    if pkg_selected "$name"; then
      echo "    需要 $1 ← $name"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------
# 单个包的产物是否已在位。
#
#   ★ 这条是「缓存缺口」的关键。host 缓存可能只有一半：
#     上次 golang 编成了、rust 因缺交叉编译器 panic，pack 时
#     「部分成功也算成功」就把 golang 单独存了。下次 unpack 成功
#     → build 被整体跳过 → rust 永远没人编 → 永远进不了缓存，
#     每次都在 Compile the firmware 里现编一遍（30~60 分钟）。
#
#   所以逐个包判断：已在位就跳过，缺哪个补哪个。
# ---------------------------------------------------------------
pkg_has_artifacts() { # $1=golang|golang-bootstrap|rust
  local d
  case "$1" in
    golang|golang-bootstrap)
      for d in $(host_stage_dirs); do [ -e "$d/bin/go" ] && return 0; done
      return 1
      ;;
    rust)
      for d in $(host_stage_dirs); do
        [ -e "$d/bin/rustc" ] && return 0
        [ -e "$d/bin/cargo" ] && return 0
      done
      return 1
      ;;
  esac
  return 1
}

case "$SUBCMD" in

# ---------------------------------------------------------------
key)
  TARGET=$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"$/\1/p' .config 2>/dev/null | head -1)
  SUBTARGET=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"$/\1/p' .config 2>/dev/null | head -1)
  [ -n "$TARGET" ] || TARGET="unknown"

  # 版本 + 包 Makefile + host 编译器版本 → 任一变化都换 key，避免复用错版本
  HASH_SRC="$(md5sum "$GO_MK" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(md5sum "$RUST_MK" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(md5sum "${GO_MK%/Makefile}/Config.in" "${RUST_MK%/Makefile}/Config.in" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(gcc --version 2>/dev/null | head -1)"
  HASH_SRC="$HASH_SRC$(g++ --version 2>/dev/null | head -1)"
  HASH_SRC="$HASH_SRC$TARGET$SUBTARGET$HOST_INCLUDE_BUILDDIR"
  HASH=$(printf '%s' "$HASH_SRC" | md5sum | cut -d' ' -f1)

  GO_TAG=$(printf '%s' "$GO_VER" | tr '.' '_')
  RUST_TAG=$(printf '%s' "$RUST_VER" | tr '.' '_')

  # 整串再过一遍白名单：TARGET/SUBTARGET 来自 .config，理论上干净，
  # 但多一道不亏 —— 这个 KEY 会被 workflow 直接插进 KEY="..." 里。
  KEY=$(sanitize "ponwrt-hosttools-${TARGET}-${SUBTARGET}-go${GO_TAG}-rs${RUST_TAG}-${HASH:0:16}")
  PREFIX=$(sanitize "ponwrt-hosttools-${TARGET}-${SUBTARGET}")

  out "HOST_CACHE_KEY=$KEY"
  out "HOST_CACHE_PREFIX=$PREFIX"
  out "HAS_GO=$HAS_GO"
  out "HAS_RUST=$HAS_RUST"
  out "GO_VER=$GO_VER"
  out "RUST_VER=$RUST_VER"
  echo "========================================"
  echo "host 缓存 Key : $KEY"
  echo "  golang=$GO_VER ($HAS_GO)  rust=$RUST_VER ($HAS_RUST)"
  echo "========================================"
  ;;

# ---------------------------------------------------------------
build)
  FAIL=0

  # 产物是否真的落地了。
  # ★ make 返回 0 不等于真编出了东西 —— 包已 installed（stamp 在）/
  #   没有 HostBuild 定义 / target 名不对时，make 都会安静地返回 0。
  #   所以退出码之外必须再看一眼产物。
  host_artifacts_present() {
    local d
    for d in $(host_stage_dirs); do
      [ -e "$d/bin/go" ]    && return 0
      [ -e "$d/bin/rustc" ] && return 0
      [ -e "$d/bin/cargo" ] && return 0
      find "$d/stamp" -maxdepth 1 -type f \
        \( -name '.golang*' -o -name '.rust*' -o -name '.go-bootstrap*' \) 2>/dev/null \
        | grep -q . && return 0
    done
    return 1
  }

  dump_diag() { # $1=场合说明
    local d
    echo "::warning::$1：make 返回 0，但 staging_dir/host* 里没有 go / rustc / stamp"
    echo "  --- 诊断 ---"
    for d in $(host_stage_dirs); do
      echo "  [$d]"
      echo "    bin 里的相关文件:"
      ls -1 "$d/bin" 2>/dev/null | grep -iE '^(go|gofmt|rustc|cargo|rustdoc)$' \
        | sed 's/^/       /' || echo "       (空或不存在)"
      echo "    stamp 里 go/rust 相关:"
      ls -1 "$d/stamp" 2>/dev/null | grep -iE 'golang|rust|go-bootstrap' | head -10 \
        | sed 's/^/       /' || echo "       (无)"
      echo "    stamp 总数: $(ls -1 "$d/stamp" 2>/dev/null | wc -l)"
    done
    echo "  4) build_dir 下的构建树:"
    ls -d build_dir/host/* build_dir/hostpkg/* 2>/dev/null | head -8 | sed 's/^/     /' || echo "     (无)"
    echo "  5) dl 里的 go/rust 源码包:"
    ls -1 dl 2>/dev/null | grep -iE '^(go|rust)' | head -5 | sed 's/^/     /' || echo "     (无)"
  }

  compile_host() { # $1=显示名 $2=package/相对路径
    local name="$1" rel="$2"
    if [ -z "$rel" ]; then
      echo "::warning::$name 不在 package/feeds 下，跳过 host 编译"
      return 0
    fi

    # 已在位就不重复编 —— 幂等，用于补齐缓存缺口
    if pkg_has_artifacts "$name"; then
      echo "⏭️  $name 产物已在位（缓存里有了），跳过编译"
      return 0
    fi

    # 源码先到位：步骤 33 的 make download 在本步之后，
    # 不补这一次的话，网络/dl 缓存出问题时编译会静默缩水。
    # ⚠ 用 package/X/download 而不是 package/X/host/download ——
    #   buildroot 只给包定义了 download，没有 host/download 这一级。
    echo "----- make package/$rel/download -----"
    make "package/$rel/download" V=s || echo "::warning::$name download 有告警，继续尝试编译"

    echo "===== make package/$rel/host/compile ($JOBS 线程) ====="
    if ! make "package/$rel/host/compile" -j"$JOBS" V=s; then
      echo "::warning::$name 多线程编译失败，单线程重试"
      if ! make "package/$rel/host/compile" -j1 V=s; then
        echo "::warning::$name host 编译失败；不写缓存，后续 make 会再试一次"
        FAIL=1
        return 0
      fi
    fi
    if host_artifacts_present; then
      echo "✅ $name host 编译完成"
    else
      # 这里只提示，完整诊断放最后统一打一次，避免几个包刷屏
      echo "::warning::$name: make 返回 0 但 staging_dir/host 里还看不到产物"
    fi
  }

  # ---------------------------------------------------------------
  # ★ 只编「真的有人用」的语言栈（need_stack / pkg_selected 见文件顶部）
  #
  #   之前是「包在 package/feeds 里就编」，结果：
  #     - HM2004-DU 的机型配置里没有任何 Go 包，却照样跑了一遍
  #       golang bootstrap（go1.4→1.17→1.20→1.22→1.24 五段自举，40~70 分钟）；
  #     - HAS_PAT=false 时私有仓库拉不下来，h3c-fttr-tools（唯一的 Rust 包）
  #       根本不在树里，rustc 也照样编了一遍。
  # ================================================================
  echo "----- 判断本次真正需要哪些 host 语言栈 -----"
  if need_stack golang-package.mk; then NEED_GO=true;   else NEED_GO=false;   echo "    无需 golang（没有选中的 Go 包）"; fi
  if need_stack rust-package.mk;   then NEED_RUST=true; else NEED_RUST=false; echo "    无需 rust（没有选中的 Rust 包）"; fi

  if [ "$NEED_GO" = "false" ] && [ "$NEED_RUST" = "false" ]; then
    echo "::warning::本次机型没有任何 Go / Rust 包，host 工具链缓存无意义，跳过"
    echo "host_build_failed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
  [ "$NEED_GO"   = "false" ] && HAS_GO=false
  [ "$NEED_RUST" = "false" ] && HAS_RUST=false

  # ---------------------------------------------------------------
  # rust 的前置条件：需要 target 交叉编译器。
  #
  #   实测 rust 的 host 编译会 configure 出
  #     --target=aarch64-unknown-linux-musl
  #     --set=target.aarch64-unknown-linux-musl.cc=aarch64-openwrt-linux-musl-gcc
  #     --set=...musl-root=staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl
  #   然后 bootstrap 的 sanity 检查会去找那个 gcc，找不到就 panic：
  #     couldn't find required command: "aarch64-openwrt-linux-musl-gcc"
  #   即 rust 的 host 构建**依赖 make toolchain/install**，不是纯 host 工具。
  #
  #   这里提前查，缺了就明确告警并跳过 rust，而不是让它 panic 后
  #   再单线程重试一遍（两种失败信息都一样，日志里很难分辨）。
  # ---------------------------------------------------------------
  if [ "$HAS_RUST" = "true" ]; then
    if ls staging_dir/toolchain*/bin/*-gcc >/dev/null 2>&1; then
      echo "target 交叉编译器: $(ls staging_dir/toolchain*/bin/*-gcc 2>/dev/null | head -1)"
    else
      echo "::warning::没有 target 交叉编译器（staging_dir/toolchain*/bin/*-gcc）"
      echo "::warning::rust 的 host 构建需要它 —— 请先跑 make toolchain/install"
      if [ "$NEED_GO" = "true" ]; then
        echo "::warning::本次跳过 rust（golang 不需要交叉编译器，仍会编）"
      else
        echo "::warning::本次跳过 rust，且无需 golang —— 没有可编的 host 语言栈"
      fi
      HAS_RUST=false
    fi
  fi

  # bootstrap 只在 CONFIG_GOLANG_BUILD_BOOTSTRAP=y 时才有意义，
  # 但包在树里就先编，make 自己会按依赖决定要不要用
  [ -n "$GO_BOOT_REL" ] && compile_host "golang-bootstrap" "$GO_BOOT_REL"
  [ "$HAS_GO" = "true" ] && compile_host "golang" "$GO_REL"
  [ "$HAS_RUST" = "true" ] && compile_host "rust" "$RUST_REL"

  # ---------------------------------------------------------------
  # ★ 部分成功也算成功。
  #
  #   golang bootstrap 是最贵的那一段（40~70 分钟，go1.4→1.17→1.20→1.22→1.24
  #   五段自举）。如果它编成了、只是 rust 失败，把结果丢掉等于下次重付一遍
  #   全部时间。所以判据改成「有没有产物」，而不是「有没有包失败」：
  #     有产物 → host_build_failed=false，pack 照常收（下次 golang 直接命中）
  #     无产物 → 才置 true，不写缓存
  # ---------------------------------------------------------------
  if ! host_artifacts_present; then
    echo "::warning::三个包都跑完了，staging_dir/host* 里仍然什么都没有"
    dump_diag "host 编译"
    FAIL=1
  elif [ "$FAIL" != "0" ]; then
    echo "::warning::部分包编译失败，但已有产物 —— 仍会打包缓存（下次可省下已完成的部分）"
    FAIL=0
  fi

  if [ "$FAIL" != "0" ]; then
    echo "host_build_failed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "host_build_failed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  ;;

# ---------------------------------------------------------------
# check：判断「还需要编什么」，用于让 workflow 决定要不要先装工具链。
#
#   存在的理由：host 缓存可能只有一半（上次 golang 编成了、rust 失败）。
#   unpack 成功 → 若 workflow 一刀切跳过工具链安装，那缺的那半永远补不上。
#   所以由这里先算出缺口，workflow 据此决定：
#     缺口为空 → 连工具链都不用装，几十秒收工
#     有缺口   → 正常装工具链（rust 缺口还要交叉编译器）再编
# ---------------------------------------------------------------
check)
  echo "----- 本次机型需要的 host 语言栈 -----"
  if need_stack golang-package.mk; then NEED_GO=true;   else NEED_GO=false;   echo "    无需 golang"; fi
  if need_stack rust-package.mk;   then NEED_RUST=true; else NEED_RUST=false; echo "    无需 rust";   fi

  GO_MISSING=false; RUST_MISSING=false
  if [ "$NEED_GO" = "true" ] && ! pkg_has_artifacts golang;   then GO_MISSING=true;   fi
  if [ "$NEED_RUST" = "true" ] && ! pkg_has_artifacts rust;   then RUST_MISSING=true; fi

  ANY=false
  { [ "$GO_MISSING" = "true" ] || [ "$RUST_MISSING" = "true" ]; } && ANY=true

  out "NEED_GO=$NEED_GO"
  out "NEED_RUST=$NEED_RUST"
  out "GO_MISSING=$GO_MISSING"
  out "RUST_MISSING=$RUST_MISSING"
  out "NEED_ANY_BUILD=$ANY"
  out "NEED_CROSS_COMPILER=$RUST_MISSING"
  echo "========================================"
  echo "golang: 需要=$NEED_GO 缺失=$GO_MISSING"
  echo "rust  : 需要=$NEED_RUST 缺失=$RUST_MISSING"
  echo "=> 还需要编译: $ANY（需要交叉编译器: $RUST_MISSING）"
  echo "========================================"
  ;;

# ---------------------------------------------------------------
pack)
  KEY="${HOST_CACHE_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 HOST_CACHE_KEY" >&2; exit 1; }

  # 只收存在的文件：缺哪个都不让 tar 失败。
  # ⚠ 三处 host 目录都要收（见 host_stage_dirs 的说明）：
  #   host / hostpkg / target-*/host —— golang 在 hostpkg，rust 在 target-*/host
  LIST=$(mktemp)
  for d in $(host_stage_dirs); do
    # 1) stamp —— 决定下次 make 会不会重编，最重要
    find "$d/stamp" -maxdepth 1 -type f \
         \( -name '.golang*' -o -name '.rust*' -o -name '.go-bootstrap*' \) 2>/dev/null >> "$LIST"
    # 2) 装进 host 的二进制与库
    for b in go gofmt rustc cargo rustdoc; do
      [ -e "$d/bin/$b" ] && echo "$d/bin/$b" >> "$LIST"
    done
    find "$d/lib" -maxdepth 1 \( -name 'go' -o -name 'go-*' -o -name 'rustlib' \) 2>/dev/null >> "$LIST"
    find "$d/libexec" -maxdepth 1 -name 'gcc-*' 2>/dev/null >> "$LIST"
    # 3) go 的工具链本体（如 lib/go-1.24.13、pkg）
    find "$d" -maxdepth 2 -type d -name 'go-1*' 2>/dev/null >> "$LIST"
  done
  # 注：rustlib 是目录，tar 会自动递归，不用再列一遍

  # ---------------------------------------------------------------
  # 4) ★ 最关键的一项：build_dir 里的 stamp 文件（只收 stamp，不收构建树）
  #
  #    为什么必须有它：HostBuild 的门禁是
  #      HOST_STAMP_PREPARED   = build_dir/.../.prepared*
  #      HOST_STAMP_CONFIGURED = build_dir/.../.configured*
  #      HOST_STAMP_BUILT      = build_dir/.../.built      ← host-compile 就看这个
  #      HOST_STAMP_INSTALLED  = staging_dir/.../stamp/.xxx_installed
  #    也就是说「有没有装好」看 staging，「要不要重编」看 build_dir/.built。
  #    只打包 staging 的二进制 + stamp，build_dir 的 .built 却丢了，
  #    下次 make 仍然判定要重编 → rustc 从零自举（30~60 分钟），
  #    缓存等于只省了个下载。这就是「缓存命中了还是很慢」的根因。
  #
  #    stamp 是空文件，几十字节，代价可以忽略；
  #    真正大的构建树仍然不收（见 HOST_INCLUDE_BUILDDIR）。
  # ---------------------------------------------------------------
  find build_dir -type f \
       \( -name '.built' -o -name '.prepared*' -o -name '.configured*' \) \
       2>/dev/null >> "$LIST"

  # 5) 可选：整个构建树（默认关，rust 的构建树 5~10GB，塞不进缓存配额）
  if [ "$HOST_INCLUDE_BUILDDIR" = "true" ]; then
    find build_dir/host build_dir/hostpkg -maxdepth 1 \
         \( -name 'golang*' -o -name 'go-*' -o -name 'go-bootstrap*' -o -name 'rust*' \) 2>/dev/null >> "$LIST"
  fi

  # 去重（多套目录可能同时命中同一文件）
  sort -u "$LIST" -o "$LIST"

  if [ ! -s "$LIST" ]; then
    echo "::warning::没有任何 host 产物可打包（go/rust 都没编出来？）"
    rm -f "$LIST"
    exit 0
  fi

  echo "打包 $(wc -l < "$LIST") 个条目："
  sed 's/^/  /' "$LIST"

  TARBALL="$HOST_CACHE_DIR/${KEY}.tzst"
  rm -f "$TARBALL"
  if tar -I zstdmt -cf "$TARBALL" -T "$LIST"; then
    ls -lh "$TARBALL"
    echo "packed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "::warning::打包失败，本次不缓存 host 工具链"
    rm -f "$TARBALL"
    echo "packed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  rm -f "$LIST"
  ;;

# ---------------------------------------------------------------
unpack)
  KEY="${HOST_CACHE_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 HOST_CACHE_KEY" >&2; exit 1; }
  TARBALL="$HOST_CACHE_DIR/${KEY}.tzst"
  if [ ! -f "$TARBALL" ]; then
    echo "restored=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::$TARBALL 不存在"
    exit 0
  fi
  which unzstd >/dev/null 2>&1 || sudo -E apt-get -yqq install zstd >/dev/null 2>&1 || true

  if ! tar -I unzstd -xf "$TARBALL"; then
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::host 工具链解压失败，将走真实编译"
    exit 0
  fi

  # tar 会还原 mtime，但解压后 stamp 相对 feeds/Makefile 的新旧关系不保证，
  # 统一 touch 一遍，确保 make 认定 host 包已装、不再重编。
  # 两套目录都要处理：host 和 hostpkg 各有各的 stamp
  while read -r d; do
    find "$d/stamp" -maxdepth 1 -type f \
         \( -name '.golang*' -o -name '.rust*' -o -name '.go-bootstrap*' \) \
         -exec touch {} + 2>/dev/null || true
  done < <(host_stage_dirs)

  # build_dir 里的 .built / .prepared* / .configured* 同样要 touch。
  # tar 还原的是旧 mtime，而源码树是刚 clone 的（mtime 是现在），
  # 不 touch 的话 make 会认为「源码比构建产物新」从而重编。
  find build_dir -type f \
       \( -name '.built' -o -name '.prepared*' -o -name '.configured*' \) \
       -exec touch {} + 2>/dev/null || true

  # 解出来却没有任何 host 二进制 = 这份缓存是空的，别让 make 以为装好了
  FOUND=0
  for d in $(host_stage_dirs); do
    [ -e "$d/bin/go" ] || [ -e "$d/bin/rustc" ] && FOUND=1
  done
  if [ "$FOUND" != "1" ]; then
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::解压后 staging_dir/host*/bin 里没有 go / rustc，视为无效缓存"
    exit 0
  fi

  echo "unpacked=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "✅ host 工具链已从缓存恢复"
  ;;

# ---------------------------------------------------------------
status)
  {
    echo "golang: $GO_VER ($HAS_GO)"
    echo "rust:   $RUST_VER ($HAS_RUST)"
    for d in $(host_stage_dirs); do
      echo "-- $d --"
      for b in go gofmt rustc cargo rustdoc; do
        if [ -e "$d/bin/$b" ]; then
          printf '%-8s %s\n' "$b" "$("$d/bin/$b" --version 2>&1 | head -1)"
        fi
      done
    done
  } | tee "$REPORT_DIR/host-toolchain.txt"
  ;;

*)
  echo "用法: $0 {key|build|pack|unpack|status} [源码树]" >&2
  exit 2
  ;;
esac
