#!/usr/bin/env bash
# =============================================================
# pwrt-cache.sh —— 整体构建缓存助手（移植自 VIKINGYFY/OpenWRT-CI）
#
#   1) 缓存对象是目录本身，不自己打 tar：
#        staging_dir/host*   host + hostpkg（go / python 在这）
#        staging_dir/tool*   交叉编译器
#        .ccache             编译对象缓存
#   2) key = 前缀 + 上游提交号，restore-keys = 前缀-
#      前缀只由「源站 + 分支 + SoC + HOST_MODE」决定，提交号变了只是换一代，
#      恢复靠前缀回退拿到最近一代 —— 这是「缓存永远命中」的来源。
#   3) 恢复后必须刷新非 target 的 stamp 并写 tmp/.build：tar 还原的是旧
#      mtime，不刷新 make 会认为源码更新 → 全量重编 → 缓存白命中。
#      ⚠ 但 tools / toolchain 的 compile 戳要按 CACHE_EXACT 区别对待，见 cmd_prepare。
#   4) 编译成功且非精确命中才存新一代，旧代交给 rollover 删掉，
#      保证 10GB 配额里每个前缀只有一份。
#
#   子命令：
#     key <dir>            算 PREFIX / KEY（写 GITHUB_OUTPUT / GITHUB_ENV）
#     prefix               只算前缀（不需要 git 仓库）
#     prepare <dir>        恢复后刷新 stamp、写 tmp/.build
#     rollover             删掉同前缀的旧代（读环境里的 PREFIX / KEY）
#     pack <ow> <outfile>  打包三个缓存目录（Release 备份通道）
#     unpack <ow> <infile> 解开 Release 备份
#     status <dir>         打印体积与版本，写 $REPORT_DIR/pwrt-cache.txt
#
#   环境变量：SOURCE / REPO_BRANCH / SOC / HOST_MODE 参与前缀；
#             GITHUB_OUTPUT / GITHUB_ENV 有就写；REPORT_DIR 默认 /tmp
# =============================================================

set -u

CMD="${1:-}"
OW="${2:-$PWD}"

# 同时写 GITHUB_OUTPUT（CI 里）和 stdout
out() {
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"
  return 0
}

# 环境变量写 GITHUB_ENV（后续 step 可读）
env_out() {
  [ -n "${GITHUB_ENV:-}" ] && echo "$1" >> "$GITHUB_ENV"
  return 0
}

# key 里只允许 [A-Za-z0-9._-]，其余一律换连字符。
# ⚠ 用 printf 而不是 echo：echo 会补换行，tr -c 会把换行也替换成 '-'，
#   key 末尾就会多一个连字符，与另一端的 key 对不上。
slug() { printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9._-' '-'; }

# ---------------------------------------------------------------
# prefix —— 只算前缀（不需要 git 仓库）
#
#   给 warm-cache 的轮换 job 用：它没有源码树，只需要知道
#   「该清理哪个前缀」。前缀算法与 key 共用同一个函数，
#   保证两处永远不会算出不同的前缀。
# ---------------------------------------------------------------
cache_prefix() {
  # ★ HOST_MODE 必须进前缀，否则两种模式的缓存会互相污染：
  #     prebuilt = 用 runner 预装的 go / rust / llvm，产物是【符号链接】
  #     source   = 从源码真实编译，产物是【真二进制】
  #   切模式后若命中对方那一份，make 看到 installed stamp 就跳过，
  #   实际拿到的是悬空链接（或缺少目标 std），错误会埋在编译期很难查。
  #   分族之后，切模式只是「换一条缓存线」，不会踩到对方的产物。
  local mode; mode=$(slug "${HOST_MODE:-prebuilt}")
  printf 'ponwrt-%s-%s-%s-%s' \
    "$(slug "${SOURCE:-unknown}")" \
    "$(slug "${REPO_BRANCH:-unknown}")" \
    "$(slug "${SOC:-unknown}")" \
    "$mode"
}

cmd_prefix() {
  local prefix; prefix=$(cache_prefix)
  out "prefix=$prefix"
  env_out "CACHE_PREFIX=$prefix"
  echo "前缀: $prefix"
}

# ---------------------------------------------------------------
# key —— 前缀 + 上游提交号
# ⚠ 刻意不把 .config / configs/*.config / diy-part*.sh 算进 key：那些只影响
#   target 侧编哪些包，不影响 host 工具链与 hostpkg；算进去就退化成「指纹一变
#   就全量重编」。target 侧每次都要重编，要复用请用 ccache。
# ⚠ 也不把机型算进前缀：前缀是 subtarget 级的，同 SoC 下所有机型共用一份。
# ---------------------------------------------------------------
cmd_key() {
  cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

  local commit prefix key
  commit=$(git rev-parse HEAD 2>/dev/null) || commit=unknown
  prefix=$(cache_prefix)
  key="${prefix}-${commit}"

  out "commit=$commit"
  out "prefix=$prefix"
  out "key=$key"
  env_out "CACHE_PREFIX=$prefix"
  env_out "CACHE_KEY=$key"

  echo "========================================"
  echo "源站    : ${SOURCE:-?}"
  echo "分支    : ${REPO_BRANCH:-?}"
  echo "SoC     : ${SOC:-?}"
  echo "提交    : $commit"
  echo "前缀    : $prefix"
  echo "本次 key: $key"
  echo "========================================"
}

# ---------------------------------------------------------------
# prepare —— 恢复缓存之后的「让 make 认账」步骤
#
#   ⚠ 范围只到「非 target」：
#     staging_dir/host/stamp、hostpkg/stamp、toolchain-*/stamp 是
#     host 侧产物，恢复后本来就该当作已装好；
#     而 staging_dir/target-*/stamp 是固件包安装标记，碰了就会
#     让 target 侧的包不重编 —— 那是错的（源码树每次都可能是新的）。
# ---------------------------------------------------------------
cmd_prepare() {
  cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

  local nstamp=0
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    find "$d" -type f -exec touch {} + 2>/dev/null || true
    nstamp=$(( nstamp + $(find "$d" -type f 2>/dev/null | wc -l) ))
  done <<< "$(find staging_dir -type d -name stamp -not -path '*target*' 2>/dev/null)"

  # ⚠ 绝对不要 touch tools/stamp-compile / toolchain/stamp-compile。
  #   它们不是文件，是 make 变量：include/subdir.mk 的 stampfile 宏把它们指向
  #     tools/stamp-compile     → staging_dir/host/stamp/.tools_compile_<flags>
  #     toolchain/stamp-compile → staging_dir/toolchain-*/stamp/.toolchain_compile
  #   在源码树里造同名空文件，只会被 scripts/timestamp.pl 的
  #     find tools -newer <戳> -print -quit
  #   命中 → 立刻判定「源码变了」→ 每轮都重跑 tools/compile 与 toolchain/compile
  #   （实测 +12'51" 与 +13'16"）。
  #
  # 只有「actions/cache 精确命中」才等于「这份缓存就是当前提交编出来的」，
  # 那时 tools/toolchain 一定完整，保留戳让 world 跳过即可；前缀回退和
  # Release 恢复都可能是别的提交、源码已变，删掉戳迫使 make 重编。
  if [ "${CACHE_EXACT:-false}" = "true" ]; then
    echo "精确命中：保留 tools / toolchain 的 compile 戳，world 会跳过这两步"
  else
    rm -f staging_dir/host/stamp/.tools_compile* 2>/dev/null || true
    for d in staging_dir/toolchain-*/stamp; do
      [ -d "$d" ] || continue
      rm -f "$d"/.toolchain_compile 2>/dev/null || true
    done
    echo "非精确命中：清掉 tools / toolchain 的 compile 戳，本轮重编这两步（ccache 会加速）"
  fi

  # 构建环境已初始化：没有它，make 会重走 prereq / prepare 阶段，
  # 表现为 tools/ toolchain/ 明明已在 staging_dir 里却又被重编一遍。
  mkdir -p tmp
  echo "1" > tmp/.build

  # 目录本身也刷一下，避免「目录比内容旧」触发不必要的重建
  find staging_dir -maxdepth 1 -type d -exec touch {} + 2>/dev/null || true

  echo "已刷新 stamp: ${nstamp} 个（不含 target）"
  echo "已写入 tmp/.build"

  # 落地校验：host gcc / go 在不在，是判断这份缓存有没有用的最快指标
  #
  # ⚠ go 的检查必须同时认符号链接（-type f -o -type l）：
  #   OpenWrt 的 staging_dir/host/bin/go 通常是指向
  #   hostpkg/lib/go-<ver>/bin/go 的链接，只找 -type f 会漏掉，
  #   于是一份完好的缓存被误报成「缺 go」。
  local miss=""
  [ -x staging_dir/host/bin/gcc ] || miss="$miss gcc"

  local go_hit
  go_hit=$(find staging_dir -path '*/bin/go' \( -type f -o -type l \) 2>/dev/null | head -1)
  [ -n "$go_hit" ] || miss="$miss go"

  if [ -n "$miss" ]; then
    echo "::warning::恢复出来的缓存缺:$miss —— host 工具链不完整，本次仍会补编"
    # 把两个 host bin 目录列出来，下一次能直接看出是「真没有」还是「路径不对」
    for d in staging_dir/host/bin staging_dir/hostpkg/bin; do
      [ -d "$d" ] || continue
      echo "  $d（前 15 项）:"
      ls -1 "$d" 2>/dev/null | head -15 | sed 's/^/    /'
    done
  else
    echo "✅ 缓存内容自检通过（gcc / go 均在）"
    echo "   go: $go_hit"
  fi
}

# ---------------------------------------------------------------
# rollover —— 删掉同前缀的旧代
#
#   key 里的提交号一变就产生新条目，旧条目再也没人用，却一直占着
#   10GB 配额。这里只留当前这一代。
#
#   ⚠ 必须等「当前 key 真的已经在缓存里」再删，否则会把唯一一份删掉 ——
#     actions/cache/save 是异步收尾的，紧接着的 job 有时还查不到。
# ---------------------------------------------------------------
cmd_rollover() {
  local prefix="${PREFIX:-${CACHE_PREFIX:-}}"
  local key="${KEY:-${CACHE_KEY:-}}"
  local repo="${GITHUB_REPOSITORY:-}"

  [ -n "$prefix" ] || { echo "::warning::缺 PREFIX，跳过轮换"; exit 0; }
  [ -n "$repo" ] || { echo "::warning::缺 GITHUB_REPOSITORY，跳过轮换"; exit 0; }
  command -v gh >/dev/null 2>&1 || { echo "::warning::无 gh，跳过轮换"; exit 0; }

  # 没给 KEY 时（warm-cache 的轮换 job 就是这种情况）：留最新创建的那一代
  #
  #   ⚠ 「最新」优先取不带 -early 的：-early 是工具链刚编完时存的早期版，
  #     只有 tools/toolchain，没有编译阶段才带出来的 hostpkg。而同提交号
  #     重跑时它往往比正式 key 还新，纯按 createdAt 会挑错。
  #     组里一条正式 key 都没有时，才退回取最新的（那就是唯一的保底）。
  if [ -z "$key" ]; then
    key=$(gh cache list -R "$repo" --key "${prefix}-" --limit 100 \
            --json key,createdAt \
            --jq 'sort_by(.createdAt) | reverse
                  | ((map(select(.key | endswith("-early") | not)) | .[0])
                     // .[0]) | .key' 2>/dev/null || true)
    if [ -z "$key" ] || [ "$key" = "null" ]; then
      echo "${prefix}- 下没有任何缓存，无需轮换"
      exit 0
    fi
    echo "未指定 KEY，按创建时间保留最新一代: $key"
  fi

  echo "目标：保留 $key，删除 ${prefix}- 下的其它条目"

  if ! gh cache list -R "$repo" --key "$key" --json key --jq '.[].key' 2>/dev/null \
       | grep -qx "$key"; then
    echo "当前 key 尚不可用（save 可能还没落库），跳过本轮轮换"
    exit 0
  fi

  local deleted=0 failed=0
  while IFS=$'\t' read -r id k; do
    [ -n "${id:-}" ] || continue
    [ "$k" = "$key" ] && continue
    echo "删除旧缓存: $k (id=$id)"
    if gh cache delete "$id" -R "$repo" 2>/dev/null; then
      deleted=$(( deleted + 1 ))
    else
      failed=$(( failed + 1 ))
      echo "::warning::删除失败 $k"
    fi
  done <<< "$(gh cache list -R "$repo" --key "${prefix}-" --limit 100 \
              --json id,key --jq '.[] | [.id,.key] | @tsv' 2>/dev/null || true)"

  echo "轮换完成：删除 $deleted 个，失败 $failed 个"
}

# ---------------------------------------------------------------
# pack / unpack —— Release 备份通道
#   actions/cache 7 天不访问就回收，Release 资产不会，所以另存一份兜底。
# ★ 只打「缓存路径那三个目录」，与 actions/cache 的 path 逐字一致，才能
#   「哪边先命中都算数」；用相对路径打包，不会把 /workdir 腌进 tar 里。
# ---------------------------------------------------------------
cache_paths() {   # 打印要打包的顶层条目（不存在的跳过）
  [ -e .ccache ] && echo ".ccache"
  ls -d staging_dir/host staging_dir/hostpkg staging_dir/toolchain* 2>/dev/null
  return 0
}

cmd_pack() {
  # ⚠ 参数必须显式传进来：函数默认拿不到脚本自己的 $3（set -u 下会直接 unbound）
  local out="${1:-}"
  cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }
  [ -n "$out" ] || { echo "::error::用法: $0 pack <openwrt_dir> <outfile>"; exit 1; }

  local list; list=$(mktemp)
  cache_paths > "$list"

  if [ ! -s "$list" ]; then
    echo "::warning::没有可打包的目录（staging_dir 还是空的？）"
    rm -f "$list"; exit 1
  fi

  echo "打包清单："
  sed 's/^/  /' "$list"

  mkdir -p "$(dirname "$out")"
  rm -f "$out"
  # zstdmt 多线程更快；没有 zstd 就退回普通 gzip-free tar
  if tar -I zstdmt -cf "$out" -T "$list" 2>/dev/null \
     || tar -I zstd -cf "$out" -T "$list" 2>/dev/null \
     || tar -cf "$out" -T "$list"; then
    ls -lh "$out"
    echo "packed=true"
  else
    echo "::warning::打包失败"
    rm -f "$out"; exit 1
  fi
  rm -f "$list"
}

cmd_unpack() {
  local in="${1:-}"
  cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }
  [ -n "$in" ] || { echo "::error::用法: $0 unpack <openwrt_dir> <infile>"; exit 1; }
  [ -f "$in" ] || { echo "::warning::$in 不存在"; exit 1; }

  if tar -I unzstd -xf "$in" 2>/dev/null \
     || tar -I zstd -xf "$in" 2>/dev/null \
     || tar -xf "$in"; then
    echo "unpacked=true"
  else
    echo "::warning::解压失败"
    exit 1
  fi
}

# ---------------------------------------------------------------
# status —— 体积与版本，落一份报告给 artifact
# ---------------------------------------------------------------
cmd_status() {
  cd "$OW" || { echo "::warning::无法进入 $OW"; exit 0; }

  local dir="${REPORT_DIR:-/tmp}"
  mkdir -p "$dir"

  {
    echo "=== staging_dir ==="
    for d in staging_dir/host staging_dir/hostpkg staging_dir/toolchain*; do
      [ -e "$d" ] || continue
      printf '%-52s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    echo ""
    echo "=== .ccache ==="
    if [ -d .ccache ]; then
      printf '%-52s %s\n' ".ccache" "$(du -sh .ccache 2>/dev/null | cut -f1)"
      [ -x staging_dir/host/bin/ccache ] && staging_dir/host/bin/ccache -s 2>/dev/null | head -12
    else
      echo "（未启用 ccache）"
    fi
    echo ""
    echo "=== 版本 ==="
    [ -x staging_dir/host/bin/gcc ] && echo "gcc : $(staging_dir/host/bin/gcc --version 2>&1 | head -1)"
    for g in staging_dir/hostpkg/bin/go1.* staging_dir/host/bin/go; do
      [ -x "$g" ] && echo "go  : $("$g" version 2>&1 | head -1)" && break
    done
    [ -x staging_dir/host/bin/rustc ] && echo "rust: $(staging_dir/host/bin/rustc --version 2>&1 | head -1)"
    ls -d staging_dir/toolchain* 2>/dev/null | head -3
    echo ""
    echo "=== 标记 ==="
    for f in tools/stamp-compile toolchain/stamp-compile tmp/.build; do
      printf '%-28s %s\n' "$f" "$([ -e "$f" ] && echo 有 || echo 无)"
    done
    echo ""
    echo "=== 提交 ==="
    git rev-parse HEAD 2>/dev/null || echo "（非 git 仓库）"
  } | tee "$dir/pwrt-cache.txt"
}

case "$CMD" in
  key)      cmd_key ;;
  prefix)   cmd_prefix ;;
  prepare)  cmd_prepare ;;
  rollover) cmd_rollover ;;
  pack)     cmd_pack   "${3:-}" ;;
  unpack)   cmd_unpack "${3:-}" ;;
  status)   cmd_status ;;
  *)
    echo "用法: $0 {key|prefix|prepare|rollover|pack|unpack|status} <openwrt_dir> [file]" >&2
    exit 1
    ;;
esac
