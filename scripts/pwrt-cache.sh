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
# host 包的 build_dir 戳 —— 缓存里到底缺了什么
#
#   include/host-build.mk 把 host 包的四个戳拆在两处：
#     INSTALLED  = staging_dir/hostpkg/stamp/.<pkg>_installed   ✅ 跟着缓存走
#     BUILT      = build_dir/host/<pkg>/.built                  ❌ 不在缓存路径
#     CONFIGURED = build_dir/host/<pkg>/.configured             ❌
#     PREPARED   = build_dir/host/<pkg>/.prepared_<md5>          ❌
#   依赖链是 installed ← built ← configured ← prepared。
#   build_dir 不缓存 → 恢复后 built 这一层不存在 → make 认为没编过 → 整条链重做。
#   source 模式下这就是 golang / rust 的完整自举：实测多 20~40 分钟、多写 13~14 GB。
#
#   所以只把「戳」冻进缓存，不冻内容：staging_dir 里已经有 installed 产物，
#   缺的只是「我做过了」这个证据。戳全是 0 字节空文件，100 来个包 × 3 个
#   ≈ 200 KB，zstd 之后不到 10 KB。
#
#   ⚠ 不能直接把 build_dir 加进 with.path：那是 13~14 GB，超 Release 单文件
#     2 GiB 上限，也会瞬间吃光 actions/cache 的 10 GB 配额。
#   ⚠ 镜像放 staging_dir/host/.builddir-stamps：staging_dir/host* 本来就在
#     缓存路径里，actions/cache 与 Release 两条通道都能自动带上，
#     不用改 workflow 的 with.path。
#   ⚠ prebuilt 模式一律不冻：那里的 go/rust 是指向 runner 的符号链接，
#     换镜像后可能悬空；宁可让同一条链重跑一遍自愈（rust-prebuilt.mk 已把
#     Prepare/Configure/Compile 置空，只花几秒）。
# ---------------------------------------------------------------
HOST_STAMP_MIRROR="staging_dir/host/.builddir-stamps"

cmd_freeze() {
  cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

  if [ "${HOST_MODE:-prebuilt}" != "source" ]; then
    # 顺手清掉上一次 source 模式留下的镜像：否则它会跟着 prebuilt 的缓存
    # 一路滚下去，将来切回 source 时又用一个早已对不上的旧镜像
    # （.prepared 的名字带源码 MD5，对不上会重建，但没必要留这个噪音）。
    rm -rf "$HOST_STAMP_MIRROR"
    echo "prebuilt 模式：不冻 build_dir 戳（产物是符号链接，重跑一遍更安全）"
    return 0
  fi

  rm -rf "$HOST_STAMP_MIRROR"
  mkdir -p "$HOST_STAMP_MIRROR"

  local n=0 rel
  while IFS= read -r -d '' f; do
    rel="${f#./}"
    mkdir -p "$HOST_STAMP_MIRROR/$(dirname "$rel")"
    cp -a "$f" "$HOST_STAMP_MIRROR/$rel" 2>/dev/null || continue
    n=$((n + 1))
  done < <(find build_dir/host build_dir/hostpkg \
             -maxdepth 2 -type f \
             \( -name '.prepared*' -o -name '.configured' -o -name '.built' \) \
             -print0 2>/dev/null)

  echo "已冻结 build_dir 戳 $n 个（$(du -sh "$HOST_STAMP_MIRROR" 2>/dev/null | cut -f1)）-> $HOST_STAMP_MIRROR"
  [ "$n" -gt 0 ] || echo "::warning::一个戳都没找到 —— build_dir 可能已被清理，下一轮仍会自举"

  # 把包名列出来：下一轮能不能跳过自举，全看这里有没有 golang / rust
  local pkgs
  pkgs=$(cd "$HOST_STAMP_MIRROR" && find . -mindepth 3 -name '.built' -printf '%h\n' 2>/dev/null \
         | sed 's#^\./##' | sort -u | head -20 | tr '\n' ' ')
  [ -n "$pkgs" ] && echo "  覆盖的 host 包: $pkgs"
}

thaw_host_stamps() {
  [ -d "$HOST_STAMP_MIRROR" ] || return 0

  if [ "${HOST_MODE:-prebuilt}" != "source" ]; then
    echo "prebuilt 模式：忽略 build_dir 戳镜像"
    return 0
  fi

  local n=0 rel
  while IFS= read -r -d '' f; do
    rel="${f#./}"
    mkdir -p "$(dirname "$rel")"
    cp -a "$HOST_STAMP_MIRROR/$rel" "$rel" 2>/dev/null || continue
    n=$((n + 1))
  done < <(cd "$HOST_STAMP_MIRROR" && find . -type f -print0)

  if [ "$n" -gt 0 ]; then
    echo "已还原 build_dir 戳 $n 个 —— 这些 host 包 make 会跳过，不再自举 go/rust"
  else
    echo "::warning::戳镜像存在但还原了 0 个，本轮仍会自举"
  fi
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

  # 先把 build_dir 的 host 戳还原回去，再刷新 staging 的戳 ——
  # 顺序不能反：还原的戳要保持构建时的旧 mtime，而 installed 要刷成「现在」，
  # 这样 installed 才比 built 新，make 不会重跑 install。
  thaw_host_stamps

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

  host_self_check
}

# ---------------------------------------------------------------
# 落地校验 —— 这份缓存到底能省掉什么
#
#   ⚠ 判断「会不会补编」不能只看二进制在不在，还要看 build_dir 里的戳在不在：
#     include/host-build.mk 把 host 包的四个戳拆在两处
#       INSTALLED  = staging_dir/hostpkg/stamp/.<pkg>_installed  ✅ 跟着缓存走
#       BUILT      = build_dir/host/<pkg>/.built                 ❌ 不在缓存路径里
#       CONFIGURED = build_dir/host/<pkg>/.configured            ❌
#       PREPARED   = build_dir/host/<pkg>/.prepared*             ❌
#     依赖是 installed ← built ← configured ← prepared，
#     恢复后 built 那一层缺失 → make 会整条链重做 → golang / rust 完整自举一遍。
#
#     prebuilt 模式对此免疫：rust-prebuilt.mk 把 Host/Prepare|Configure|Compile
#     全部置空、Install 只剩三个 ln -sfn，同一条链重跑只要几秒；
#     source 模式则是真自举 —— 实测每次多写 13~14 GB、多花 20~40 分钟。
# ---------------------------------------------------------------
host_self_check() {
  local miss=""
  [ -x staging_dir/host/bin/gcc ] || miss="$miss gcc"

  # ⚠ go / rustc 的检查必须同时认符号链接（-type f -o -type l）：
  #   staging_dir/host/bin/go 常是指向 hostpkg/lib/go-*/bin/go 的链接，
  #   prebuilt 模式下 rustc 则是指向 runner rustup 的链接，
  #   只找 -type f 会把一份完好的缓存误报成「缺」。
  local go_hit rustc_hit cargo_hit
  go_hit=$(find staging_dir -path '*/bin/go'    \( -type f -o -type l \) 2>/dev/null | head -1)
  rustc_hit=$(find staging_dir -path '*/bin/rustc' \( -type f -o -type l \) 2>/dev/null | head -1)
  cargo_hit=$(find staging_dir -path '*/bin/cargo' \( -type f -o -type l \) 2>/dev/null | head -1)

  echo "=== host 工具链自检 ==="
  probe_bin() {  # <名字> <路径>
    local name="$1" p="$2"
    if [ -z "$p" ]; then echo "  $name : 不存在"; return 0; fi
    if [ -L "$p" ] && [ ! -e "$p" ]; then
      echo "  $name : ❌ 悬空符号链接 -> $(readlink "$p")"
    elif [ -L "$p" ]; then
      echo "  $name : 符号链接 -> $(readlink "$p")"
    else
      echo "  $name : 真实文件 $p"
      "$p" --version 2>/dev/null | head -1 | sed "s/^/          /" || true
    fi
  }
  probe_bin gcc   "$([ -x staging_dir/host/bin/gcc ] && echo staging_dir/host/bin/gcc)"
  probe_bin go    "$go_hit"
  probe_bin rustc "$rustc_hit"
  probe_bin cargo "$cargo_hit"

  # build_dir 的戳还在不在 —— 这决定 source 模式要不要重新自举。
  # ⚠ 判据是「installed 戳在、built 戳不在」，不能只看有没有二进制：
  #   前者才是 make 真正要追的目标；后者只有踩过完整链才会留下。
  local nbuilt nconf nprep ninst
  nbuilt=$(find build_dir/host build_dir/hostpkg -maxdepth 2 -type f -name '.built'      2>/dev/null | wc -l)
  nconf=$( find build_dir/host build_dir/hostpkg -maxdepth 2 -type f -name '.configured' 2>/dev/null | wc -l)
  nprep=$( find build_dir/host build_dir/hostpkg -maxdepth 2 -type f -name '.prepared*'  2>/dev/null | wc -l)
  ninst=$(find staging_dir/host/stamp staging_dir/hostpkg/stamp -maxdepth 1 -type f -name '*_installed' 2>/dev/null | wc -l)
  echo "  host 戳 installed=$ninst（staging_dir）  built=$nbuilt configured=$nconf prepared=$nprep（build_dir）"

  if [ "$ninst" -gt 0 ] && [ "$nbuilt" -eq 0 ]; then
    echo "::warning::host 包只有 installed 戳、build_dir 的 built 戳一个都没有 ——"
    echo "          make 会重跑 installed←built←configured←prepared 整条链"
    if [ "${HOST_MODE:-prebuilt}" = "source" ]; then
      echo "          source 模式下这就是 golang / rust 自举，实测多花 20~40 分钟、多写 13~14 GB"
      echo "          （build_dir 不在缓存路径里，所以同 key 精确命中也躲不掉）"
    else
      echo "          prebuilt 模式下被 rust-prebuilt.mk 挡掉（几秒），影响很小"
    fi
  elif [ "$nbuilt" -gt 0 ]; then
    echo "✅ build_dir 的 built 戳也在，host 包的自举会整段跳过"
  fi

  if [ -n "$miss" ]; then
    echo "::warning::恢复出来的缓存缺:$miss —— host 工具链不完整，本次仍会补编"
    for d in staging_dir/host/bin staging_dir/hostpkg/bin; do
      [ -d "$d" ] || continue
      echo "  $d（前 15 项）:"
      ls -1 "$d" 2>/dev/null | head -15 | sed 's/^/    /'
    done
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
    echo "=== build_dir（不在缓存里，决定要不要重新自举） ==="
    for d in build_dir/host build_dir/hostpkg; do
      [ -e "$d" ] || continue
      printf '%-52s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    printf '%-52s %s\n' "  .built 戳" \
      "$(find build_dir/host build_dir/hostpkg -maxdepth 2 -type f -name '.built' 2>/dev/null | wc -l) 个"
    printf '%-52s %s\n' "$HOST_STAMP_MIRROR（冻进缓存的镜像）" \
      "$([ -d "$HOST_STAMP_MIRROR" ] && echo "$(du -sh "$HOST_STAMP_MIRROR" 2>/dev/null | cut -f1) / $(find "$HOST_STAMP_MIRROR" -type f 2>/dev/null | wc -l) 个戳" || echo 无)"
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
  freeze)   cmd_freeze ;;
  unpack)   cmd_unpack "${3:-}" ;;
  status)   cmd_status ;;
  *)
    echo "用法: $0 {key|prefix|prepare|freeze|rollover|pack|unpack|status} <openwrt_dir> [file]" >&2
    exit 1
    ;;
esac
