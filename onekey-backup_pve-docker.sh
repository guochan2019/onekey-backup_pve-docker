#!/bin/bash
# ============================================================
# onekey-backup_pve-docker — Docker 数据一键备份/还原脚本
# 适用环境: PVE 宿主 / Docker LXC（能访问 /mnt/nvme1 与 /mnt/backup 的机器）
# 功能:
#   备份: /mnt/nvme1/ 下的一级目录，按类型打包 .tar.zst 到备份目录
#         - 容器目录 (appdata/appdata_deb): 其下容器子目录分别打包
#           输出: <备份目录>/<容器目录>/<容器名>_<YYYYMMDD>.tar.zst
#         - 其他目录 (docker/docker_deb/mediaout): 整个目录打包
#           输出: <备份目录>/<目录名>_<YYYYMMDD>.tar.zst
#   还原: 扫描备份目录顶层 + 各容器子目录的最新备份，分组展示
#         选择支持: 编号 / 范围 / 关键字模糊匹配 / v<编号>历史版本 / a全部
#         解包: 顶层包 → 还原目录/；容器包 → 还原目录/<容器目录>/
# 压缩: zstd 多线程 (zstd -T${ZSTD_THREADS} -6)，nice+ionice 降优先级不抢资源
#       还原自动识别 .tar.zst / .tar.bz2
# ============================================================
set -e

trap 'echo -e "\033[0;31m[ERROR] 脚本执行失败，请检查:\033[0m
  - 备份/还原目录是否可读写
  - 磁盘空间是否充足
  - 尝试: bash -x onekey-backup_pve-docker.sh" >&2' ERR

# ---------- 配置 ----------
SOURCE_ROOT="/mnt/nvme1"                 # 备份源根目录
BACKUP_ROOT="/mnt/backup/pve-docker"     # 备份目标目录（可交互修改）
RESTORE_ROOT="/mnt/nvme1"                # 还原目标目录（可交互修改）
CONTAINER_DIRS="appdata appdata_deb"     # 容器目录列表（其下子目录分别打包，新增在此扩展）
ZSTD_THREADS="${ZSTD_THREADS:-$(nproc)}"  # zstd 压缩线程数（默认全核；临时调: ZSTD_THREADS=4 bash 脚本；改默认值直接改此行）

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 人类可读大小（无 numfmt 依赖） ----------
human_size() {
  local b=$1
  if [ "$b" -ge 1073741824 ]; then
    echo "$((b/1073741824))G"
  elif [ "$b" -ge 1048576 ]; then
    echo "$((b/1048576))M"
  elif [ "$b" -ge 1024 ]; then
    echo "$((b/1024))K"
  else
    echo "${b}B"
  fi
}

# ---------- 等待 tar 完成 + 进度轮询 + 退出码容错 ----------
# tar 退出码: 0=成功, 1=警告(file changed as we read it 等, 容忍并提示), >=2=错误
# $1=PID  $2=显示名  $3=轮询路径(文件走 du -h, 目录走 du -sb 增量)  $4=目录基准字节
# $5=序号  $6=总数  $7=进度动词  $8=stderr 日志文件
wait_tar() {
  local pid="$1" name="$2" watch="$3" base="$4" i="$5" n="$6" verb="$7" errlog="$8"
  local start last cur inc size rc last_print
  start=$(date +%s)
  last=""
  last_print=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ -d "$watch" ]; then
      cur=$(du -sb "$watch" 2>/dev/null | cut -f1 || echo "$base")
      inc=$((cur - base))
      [ "$inc" -lt 0 ] && inc=0
      size=$(human_size "$inc")
    else
      size=$(du -h "$watch" 2>/dev/null | cut -f1)
    fi
    # 大小变化 或 距上次打印 >=10 秒（防大目录长时间无刷新被误判卡死）都强制刷新
    now=$(date +%s)
    if [ -n "$size" ] && { [ "$size" != "$last" ] || [ $(( now - last_print )) -ge 10 ]; }; then
      printf "\r    [%d/%d] %s: %s %s (%ds)   " "$i" "$n" "$name" "$verb" "$size" "$(( now - start ))"
      last_print=$now
    fi
    last="$size"
    sleep 2
  done
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  printf "\r    [%d/%d] %s: 完成 (%ds)   \n" "$i" "$n" "$name" "$(( $(date +%s) - start ))"
  if [ -s "$errlog" ]; then
    # 警告分类：socket ignored=正常忽略(降级 info)，file changed=一致性风险(warn)
    if grep -q 'socket ignored' "$errlog"; then
      info "  ℹ tar 提示: 已忽略 socket 文件（正常——socket 无法归档且无需备份）"
    fi
    if grep -q 'file changed' "$errlog"; then
      warn "  ⚠ tar 警告: $(tr '\n' ' ' < "$errlog" | grep -o 'file changed as we read it[^,]*' | head -1)"
      warn "    （打包期间文件被修改，常见于运行中的数据库/服务——该包可能不一致，建议停服后重备）"
    fi
  fi
  rm -f "$errlog"
  return "$rc"
}

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 依赖检查（zstd 缺失自动安装） ----------
if ! command -v zstd >/dev/null 2>&1; then
  warn "缺少 zstd，正在安装 (apt-get install zstd)..."
  apt-get update -qq
  apt-get install -y -qq zstd || err "zstd 安装失败，请手动执行: apt install zstd"
  if ! command -v zstd >/dev/null 2>&1; then
    err "zstd 安装后仍不可用，请手动检查"
  fi
  info "  ✓ zstd 已就绪 ($(zstd --version 2>/dev/null | head -1))"
fi

# ---------- 路径校验（绝对路径 + 非根） ----------
check_abs_path() {
  case "$1" in
    /*) ;;
    *) err "路径必须是绝对路径: $1" ;;
  esac
  if [ "$1" = "/" ]; then
    err "禁止使用 / 作为目录"
  fi
}

# ---------- 判断是否容器目录 ----------
is_container_dir() {
  local d="$1"
  for c in $CONTAINER_DIRS; do
    if [ "$d" = "$c" ]; then
      return 0
    fi
  done
  return 1
}

# ---------- 备份 ----------
do_backup() {
  echo ""
  warn "========== 备份 Docker 数据 =========="
  echo ""

  [ -d "$SOURCE_ROOT" ] || err "源目录不存在: ${SOURCE_ROOT}"

  # 1. 列出源根下所有一级目录
  mapfile -t DIRS < <(find "$SOURCE_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  if [ "${#DIRS[@]}" -eq 0 ]; then
    err "源目录 ${SOURCE_ROOT} 下没有子目录可备份"
  fi

  # 2. 显示待备份内容（分类展示）
  echo "源目录: ${SOURCE_ROOT}"
  echo "待备份内容:"
  for d in "${DIRS[@]}"; do
    if is_container_dir "$d"; then
      mapfile -t SUBS < <(find "$SOURCE_ROOT/$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
      if [ "${#SUBS[@]}" -eq 0 ]; then
        warn "  - ${d}/ (容器目录，无子目录，跳过)"
      else
        warn "  - ${d}/ (容器目录，${#SUBS[@]} 个容器子目录分别打包)"
        for s in "${SUBS[@]}"; do
          info "      - $s"
        done
      fi
    else
      if findmnt "$SOURCE_ROOT/$d" >/dev/null 2>&1; then
        warn "  - $d (整体打包，⚠ 挂载点，备份将包含其挂载内容)"
      else
        info "  - $d (整体打包)"
      fi
    fi
  done
  echo ""

  # 3. 交互确认备份目录（默认 BACKUP_ROOT，可修改）
  read -p "备份目录 (默认 ${BACKUP_ROOT}): " BK_DIR </dev/tty
  BK_DIR="${BK_DIR:-$BACKUP_ROOT}"
  check_abs_path "$BK_DIR"
  case "$BK_DIR" in
    "$SOURCE_ROOT"|"${SOURCE_ROOT}"/*) warn "  ⚠ 备份目录在源目录内部（同一挂载），备份文件会占用源盘空间" ;;
  esac
  mkdir -p "$BK_DIR"

  # 4. 统计总包数（进度用）
  TOTAL=0
  for d in "${DIRS[@]}"; do
    if is_container_dir "$d"; then
      N=$(find "$SOURCE_ROOT/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
      TOTAL=$((TOTAL+N))
    else
      TOTAL=$((TOTAL+1))
    fi
  done

  # 5. 逐个打包
  DATE=$(date +%Y%m%d)
  echo ""
  info "=== 开始打包 (${DATE}) ==="
  i=0
  for d in "${DIRS[@]}"; do
    if is_container_dir "$d"; then
      mapfile -t SUBS < <(find "$SOURCE_ROOT/$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
      [ "${#SUBS[@]}" -eq 0 ] && continue
      mkdir -p "$BK_DIR/$d"
      for s in "${SUBS[@]}"; do
        i=$((i+1))
        PKG="${BK_DIR}/${d}/${s}_${DATE}.tar.zst"
        if [ -f "$PKG" ]; then
          warn "  [${i}/${TOTAL}] ${d}/${s} 存在同日备份，覆盖重新打包"
        else
          info "  [${i}/${TOTAL}] ${d}/${s} ..."
        fi
        # 后台打包 + 进度轮询；tar 退出码 1(运行中文件变化) 容忍并提示，>=2 报错停
        ERRLOG=$(mktemp)
        nice -n 19 ionice -c3 tar -I "zstd -T${ZSTD_THREADS} -6" -cf "$PKG" -C "$SOURCE_ROOT/$d" "$s" 2>"$ERRLOG" &
        TAR_PID=$!
        RC=0
        wait_tar "$TAR_PID" "${d}/${s}" "$PKG" 0 "$i" "$TOTAL" "已打包" "$ERRLOG" || RC=$?
        if [ "$RC" -ge 2 ]; then
          err "打包失败: ${d}/${s} (tar 退出码 ${RC})"
        fi
      done
    else
      i=$((i+1))
      PKG="${BK_DIR}/${d}_${DATE}.tar.zst"
      if [ -f "$PKG" ]; then
        warn "  [${i}/${TOTAL}] ${d} 存在同日备份，覆盖重新打包"
      else
        info "  [${i}/${TOTAL}] ${d} ..."
      fi
      # 后台打包 + 进度轮询；tar 退出码 1 容忍并提示，>=2 报错停
      ERRLOG=$(mktemp)
      nice -n 19 ionice -c3 tar -I "zstd -T${ZSTD_THREADS} -6" -cf "$PKG" -C "$SOURCE_ROOT" "$d" 2>"$ERRLOG" &
      TAR_PID=$!
      RC=0
      wait_tar "$TAR_PID" "$d" "$PKG" 0 "$i" "$TOTAL" "已打包" "$ERRLOG" || RC=$?
      if [ "$RC" -ge 2 ]; then
        err "打包失败: ${d} (tar 退出码 ${RC})"
      fi
    fi
  done

  # 6. 汇总
  echo ""
  info "========== 备份完成 =========="
  for f in "$BK_DIR"/*_${DATE}.tar.zst; do
    [ -f "$f" ] && printf "  %-46s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  for sub in "$BK_DIR"/*/; do
    [ -d "$sub" ] || continue
    for f in "$sub"*_${DATE}.tar.zst; do
      [ -f "$f" ] && printf "  %-46s %s\n" "$(basename "$sub")/$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
  done
  echo ""
}

# ---------- 还原 ----------
do_restore() {
  echo ""
  warn "========== 还原 Docker 数据 =========="
  echo ""

  [ -d "$BACKUP_ROOT" ] || err "备份目录不存在: ${BACKUP_ROOT}"

  # 1. 扫描备份：顶层包（type=root）+ 各容器子目录包（type=子目录名）
  #    同时收集每个条目的全部版本（VER_DATES/VER_PKGS 换行分隔，按扫描序=日期升序）
  declare -A LATEST LATEST_DATE LATEST_TYPE VER_DATES VER_PKGS
  collect_backup() {
    local dir="$1" type="$2" f name dir_name date_part key
    [ "${dir: -1}" = "/" ] || dir="$dir/"
    for f in "$dir"*.tar.zst "$dir"*.tar.bz2; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      name="${name%%.tar.*}"    # 去 .tar.zst / .tar.bz2 后缀
      dir_name="${name%_*}"
      date_part="${name##*_}"
      case "$date_part" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
          key="${type}/${dir_name}"
          VER_DATES[$key]+="$date_part
"
          VER_PKGS[$key]+="$f
"
          if [ -z "${LATEST_DATE[$key]+x}" ] || [ "$date_part" \> "${LATEST_DATE[$key]}" ]; then
            LATEST[$key]="$f"
            LATEST_DATE[$key]="$date_part"
            LATEST_TYPE[$key]="$type"
          fi
          ;;
      esac
    done
  }
  collect_backup "$BACKUP_ROOT" "root"
  for subdir in "$BACKUP_ROOT"/*/; do
    [ -d "$subdir" ] || continue
    collect_backup "$subdir" "$(basename "$subdir")"
  done
  if [ "${#LATEST[@]}" -eq 0 ]; then
    err "备份目录 ${BACKUP_ROOT} 下没有 <目录名>_<YYYYMMDD>.tar.zst / .tar.bz2 格式的备份"
  fi

  # 2. 排序：root 组优先，组内字母序
  mapfile -t KEYS < <(printf '%s\n' "${!LATEST[@]}" | sort -t/ -k1,1r -k2,2)

  # 3. 显示最新备份列表（分组）
  echo "备份目录: ${BACKUP_ROOT}"
  echo "可用备份（最新版本）:"
  PREV_TYPE=""
  n=0
  for k in "${KEYS[@]}"; do
    type="${k%%/*}"
    name="${k#*/}"
    if [ "$type" != "$PREV_TYPE" ]; then
      if [ "$type" = "root" ]; then
        echo "[顶层目录]"
      else
        echo "[${type} 容器]"
      fi
      PREV_TYPE="$type"
    fi
    n=$((n+1))
    printf "  [%d] %-16s %s (%s)\n" "$n" "$name" "$(basename "${LATEST[$k]}")" "$(du -h "${LATEST[$k]}" | cut -f1)"
  done
  echo ""

  # 4. 多轮选择（编号/范围/关键字/v历史版本/a全部/回车完成）
  declare -A SELECTED   # key -> 包路径
  while true; do
    if [ "${#SELECTED[@]}" -gt 0 ]; then
      read -p "已选 ${#SELECTED[@]} 项。输入还原目标（编号/范围/关键字，v<编号>看历史版本，a=全部，回车完成）: " SELECT </dev/tty
    else
      read -p "输入还原目标（编号/范围/关键字，v<编号>看历史版本，a=全部）: " SELECT </dev/tty
    fi
    SELECT=$(echo "$SELECT" | tr -s ' ')
    [ -z "$SELECT" ] && break

    # v 历史版本（v4 或 v 4）
    case "$SELECT" in
      [vV][0-9]*|[vV][[:space:]][0-9]*)
        rest="${SELECT#[vV]}"
        for nn in $rest; do
          case "$nn" in
            *[!0-9]*) err "无效编号: ${nn}" ;;
          esac
          [ "$nn" -ge 1 ] && [ "$nn" -le "${#KEYS[@]}" ] || err "编号越界: ${nn}"
          k="${KEYS[$((nn-1))]}"
          mapfile -t vdates < <(printf '%s' "${VER_DATES[$k]}")
          mapfile -t vpkgs < <(printf '%s' "${VER_PKGS[$k]}")
          # 按日期降序（最新在前，回车默认=最新）
          PAIRED=$(paste -d'|' <(printf '%s\n' "${vdates[@]}") <(printf '%s\n' "${vpkgs[@]}") | sort -t'|' -k1,1r)
          mapfile -t vdates < <(printf '%s\n' "$PAIRED" | cut -d'|' -f1)
          mapfile -t vpkgs < <(printf '%s\n' "$PAIRED" | cut -d'|' -f2)
          echo ""
          echo "[${k}] 全部备份版本 (${#vdates[@]} 个):"
          j=0
          for vd in "${vdates[@]}"; do
            j=$((j+1))
            printf "  [%d] %s (%s)\n" "$j" "$(basename "${vpkgs[$((j-1))]}")" "$(du -h "${vpkgs[$((j-1))]}" | cut -f1)"
          done
          read -p "输入版本编号 (回车=最新): " VN </dev/tty
          VN=${VN:-1}
          case "$VN" in
            *[!0-9]*) err "无效版本编号: ${VN}" ;;
          esac
          [ "$VN" -ge 1 ] && [ "$VN" -le "${#vdates[@]}" ] || err "版本编号越界: ${VN}"
          SELECTED[$k]="${vpkgs[$((VN-1))]}"
          info "  已选: $(basename "${vpkgs[$((VN-1))]}")"
        done
        continue
        ;;
    esac

    # a 全部
    case "$SELECT" in
      a|A)
        for k in "${KEYS[@]}"; do
          SELECTED[$k]="${LATEST[$k]}"
        done
        break
        ;;
    esac

    # 编号 / 范围 / 关键字（read -ra 分词且不做 glob 展开，关键字含 * ? [ 安全）
    read -ra TOKS <<< "$SELECT"
    for tok in "${TOKS[@]}"; do
      case "$tok" in
        *-*)  # 范围 2-5
          a="${tok%-*}"
          b="${tok#*-}"
          case "$a" in *[!0-9]*) err "无效范围: ${tok}" ;; esac
          case "$b" in *[!0-9]*) err "无效范围: ${tok}" ;; esac
          [ "$a" -ge 1 ] && [ "$b" -le "${#KEYS[@]}" ] || err "范围越界: ${tok}"
          [ "$a" -le "$b" ] || err "范围起止颠倒: ${tok}"
          for ((m=a; m<=b; m++)); do
            SELECTED["${KEYS[$((m-1))]}"]="${LATEST[${KEYS[$((m-1))]}]}"
          done
          ;;
        *[!0-9]*)  # 关键字模糊匹配
          HIT=0
          for k in "${KEYS[@]}"; do
            if [[ "$k" == *"$tok"* ]]; then
              SELECTED[$k]="${LATEST[$k]}"
              HIT=1
            fi
          done
          if [ "$HIT" -eq 0 ]; then
            warn "  未匹配到含 '${tok}' 的备份项"
          fi
          ;;
        *)  # 编号
          [ "$tok" -ge 1 ] && [ "$tok" -le "${#KEYS[@]}" ] || err "编号越界: ${tok}"
          SELECTED["${KEYS[$((tok-1))]}"]="${LATEST[${KEYS[$((tok-1))]}]}"
          ;;
      esac
    done
  done

  if [ "${#SELECTED[@]}" -eq 0 ]; then
    err "未选择任何备份"
  fi

  # 5. 构建还原项（按 KEYS 顺序）
  RESTORE_ITEMS=()
  for k in "${KEYS[@]}"; do
    if [ -n "${SELECTED[$k]+x}" ]; then
      RESTORE_ITEMS+=("${k%%/*}|${SELECTED[$k]}")
    fi
  done

  # 6. 交互确认还原目录（默认 RESTORE_ROOT，可修改）
  read -p "还原目录 (默认 ${RESTORE_ROOT}): " RS_DIR </dev/tty
  RS_DIR="${RS_DIR:-$RESTORE_ROOT}"
  check_abs_path "$RS_DIR"
  [ -d "$RS_DIR" ] || mkdir -p "$RS_DIR"

  # 7. 覆盖确认（显示每个包的实际解包目标）
  echo ""
  echo "将解包以下备份:"
  for it in "${RESTORE_ITEMS[@]}"; do
    type="${it%%|*}"
    pkg="${it#*|}"
    if [ "$type" = "root" ]; then
      echo "  - $(basename "$pkg") → ${RS_DIR}/"
    else
      echo "  - $(basename "$pkg") → ${RS_DIR}/${type}/"
    fi
  done
  read -p "确认还原？(y/n，默认 n): " CONFIRM </dev/tty
  CONFIRM=${CONFIRM:-n}
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    info "已取消还原"
    exit 0
  fi

  # 8. 解包
  echo ""
  info "=== 开始还原 ==="
  i=0
  for it in "${RESTORE_ITEMS[@]}"; do
    i=$((i+1))
    type="${it%%|*}"
    pkg="${it#*|}"
    if [ "$type" = "root" ]; then
      TARGET="$RS_DIR"
    else
      TARGET="$RS_DIR/$type"
      mkdir -p "$TARGET"
    fi
    info "  [${i}/${#RESTORE_ITEMS[@]}] $(basename "$pkg") → ${TARGET}/"
    # 后台解压 + 进度轮询；tar 退出码 1 容忍并提示，>=2 报错停
    BASE_SIZE=$(du -sb "$TARGET" 2>/dev/null | cut -f1 || echo 0)
    ERRLOG=$(mktemp)
    nice -n 19 ionice -c3 tar -xf "$pkg" -C "$TARGET" 2>"$ERRLOG" &   # 解压同样降优先级
    TAR_PID=$!
    RC=0
    wait_tar "$TAR_PID" "$(basename "$pkg")" "$TARGET" "$BASE_SIZE" "$i" "${#RESTORE_ITEMS[@]}" "已解压" "$ERRLOG" || RC=$?
    if [ "$RC" -ge 2 ]; then
      err "还原失败: $(basename "$pkg") (tar 退出码 ${RC})"
    fi
  done

  # 9. 汇总
  echo ""
  info "========== 还原完成 =========="
  for it in "${RESTORE_ITEMS[@]}"; do
    type="${it%%|*}"
    pkg="${it#*|}"
    name=$(basename "$pkg")
    name="${name%%.tar.*}"
    dir_name="${name%_*}"
    if [ "$type" = "root" ]; then
      [ -d "$RS_DIR/$dir_name" ] && info "  ✓ $RS_DIR/$dir_name"
    else
      [ -d "$RS_DIR/$type/$dir_name" ] && info "  ✓ $RS_DIR/$type/$dir_name"
    fi
  done
  echo ""
}

# ---------- 菜单 ----------
echo ""
echo "============================================"
echo "  Docker 数据一键备份/还原脚本"
echo "============================================"
echo ""
echo "  源目录:   ${SOURCE_ROOT}"
echo "  备份目录: ${BACKUP_ROOT}"
echo ""
echo "请选择操作："
echo "  1. 备份"
echo "  2. 还原"
echo "  0. 退出"
echo ""
read -p "请输入选项 (0-2): " ACTION </dev/tty
echo ""

case "$ACTION" in
  1) do_backup ;;
  2) do_restore ;;
  0) info "已退出"; exit 0 ;;
  *) err "无效选项: ${ACTION}" ;;
esac
