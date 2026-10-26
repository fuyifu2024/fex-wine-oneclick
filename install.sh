#!/usr/bin/env bash
#
# fex-wine-oneclick —— 在 ARM64 Ubuntu 上一键安装 FEX 转译层 + x86-64 Wine，
# 让 Windows 的 .exe 可以双击直接打开。
#
# 用法:
#   ./install.sh              安装（需要 sudo，会提示输一次密码）
#   ./install.sh --check      只检查状态，不做任何修改
#   ./install.sh --uninstall  卸载本脚本装的东西（FEX 的 apt 包保留）
#   ./install.sh --purge      连 FEX 的 apt 包和 PPA 一起卸载
#   ./install.sh --help       看帮助
#
# 适用: Raspberry Pi 5 / 其它 4K 页大小、ARMv8.2+ 的 Ubuntu 24.04+ (arm64)
# 限制: 只支持 64 位 Windows 程序；性能为「能用」级，不适合大游戏。
# 许可: MIT

set -euo pipefail

REPO_URL="https://github.com/fuyifu2024/fex-wine-oneclick"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# —— 安装路径（XDG 规范）——
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
FEX_DATA="$XDG_DATA_HOME/fex-emu"
ROOTFS_NAME="Ubuntu_24_04"
ROOTFS_DIR="$FEX_DATA/RootFS/$ROOTFS_NAME"
FEX_CONFIG="$HOME/.fex-emu/Config.json"
PREFIX="$HOME/.wine-fex"
ZROOT="$HOME/.fex-zroot"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/fex-wine"
DESKTOP_DIR="$XDG_DATA_HOME/applications"
DESKTOP="$DESKTOP_DIR/fex-wine.desktop"
CACHE_DIR="$HOME/.cache/fex-wine"
MIME_EXE="application/vnd.microsoft.portable-executable"
MIME_EXE_LEGACY="application/x-ms-dos-executable"

# —— 输出小工具 ——
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { c_err "错误: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

# —— CPU 等级（决定装 fex-emu-armv8.x 哪一档）——
detect_cpu_tier() {
  local feats tier
  feats=$(grep -m1 '^Features' /proc/cpuinfo | cut -d: -f2-)
  has_feat() { [[ " $feats " == *" $1 "* ]]; }
  if has_feat flagm && has_feat asimddp; then
    tier="armv8.4"
  elif has_feat asimdrdm && has_feat asimddp; then
    tier="armv8.2"
  elif has_feat crc32 && has_feat asimd; then
    tier="armv8.0"
  else
    die "CPU 不满足 FEX 的最低要求（ARMv8.0 + crc32 + asimd）"
  fi
  echo "$tier"
}

preflight() {
  section "预检"
  [ "$EUID" -ne 0 ] || die "请用普通用户运行（脚本内部会用 sudo），不要直接 sudo ./install.sh"
  [ "$(uname -m)" = "aarch64" ] || die "只支持 ARM64（aarch64）主机，当前是 $(uname -m)"

  local ps
  ps=$(getconf PAGESIZE)
  [ "$ps" = "4096" ] || die "FEX 要求 4K 页大小的内核，当前是 ${ps} 字节（16K/64K 页跑不了 FEX）"
  c_ok "页大小 4K ✅"

  TIER=$(detect_cpu_tier)
  c_ok "CPU 等级: $TIER"

  have python3 || die "缺少 python3（sudo apt install python3）"
  have curl || die "缺少 curl（sudo apt install curl）"

  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "只支持 Ubuntu（当前 ID=${ID:-?}）"
  local suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [ -n "$suite" ] || die "识别不出 Ubuntu 发行版代号"
  c_ok "系统: ${PRETTY_NAME:-Ubuntu} ($suite)"

  if ! curl -sfI --max-time 20 "https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu/dists/$suite/Release" >/dev/null; then
    die "FEX PPA 没有 $suite 的构建（查看 https://launchpad.net/~fex-emu/+archive/ubuntu/fex）"
  fi
  c_ok "FEX PPA 有 $suite 的构建 ✅"

  local avail_kb
  avail_kb=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
  [ "$avail_kb" -ge $((7 * 1024 * 1024)) ] || \
    die "磁盘空间不足：需要约 7GB，$HOME 只剩 $((avail_kb / 1024 / 1024))GB"
  c_ok "磁盘空间充足（$(df -Ph "$HOME" | awk 'NR==2{print $4}') 可用）"
}

step_apt() {
  section "1/7 安装 FEX（apt）"
  local pkgs=("fex-emu-$TIER" fex-emu-binfmt64 fex-emu-binfmt32)
  if dpkg -s "${pkgs[@]}" >/dev/null 2>&1; then
    c_ok "FEX 已安装，跳过"
  else
    if ! apt-cache policy "fex-emu-$TIER" 2>/dev/null | grep -q 'ppa.launchpadcontent.net/fex-emu'; then
      c_ok "添加 FEX PPA ..."
      as_root apt-get install -y software-properties-common >/dev/null 2>&1 || true
      as_root add-apt-repository -y ppa:fex-emu/fex
    fi
    as_root apt-get update
    as_root apt-get install -y "${pkgs[@]}"
  fi
  if ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qi '^FEX'; then
    c_ok "binfmt 已注册: $(ls /proc/sys/fs/binfmt_misc/ | grep -i '^FEX' | tr '\n' ' ')"
  else
    c_warn "没看到 FEX 的 binfmt 条目，尝试重启 systemd-binfmt ..."
    as_root systemctl restart systemd-binfmt || true
  fi
}

step_rootfs() {
  section "2/7 下载并解包 x86-64 RootFS（Ubuntu 24.04）"
  if [ -x "$ROOTFS_DIR/usr/bin/true" ]; then
    c_ok "RootFS 已存在: $ROOTFS_DIR"
    return
  fi
  mkdir -p "$FEX_DATA/RootFS" "$CACHE_DIR"
  have unsquashfs || die "缺少 unsquashfs（sudo apt install squashfs-tools）"

  local json="$CACHE_DIR/RootFS_links.json"
  [ -s "$json" ] || curl -fsSL --retry 3 -o "$json" "https://rootfs.fex-emu.gg/RootFS_links.json"
  local url
  url=$(python3 - "$json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for _name, v in d.get("v1", {}).items():
    if v.get("DistroMatch") == "ubuntu" and v.get("DistroVersion") == "24.04" and v.get("Type") == "squashfs":
        print(v["URL"])
        break
PY
)
  [ -n "$url" ] || die "RootFS 索引里没找到 Ubuntu 24.04 squashfs 镜像"

  local img="$FEX_DATA/RootFS/${ROOTFS_NAME}.sqsh"
  if [ -s "$img" ] && unsquashfs -s "$img" >/dev/null 2>&1; then
    c_ok "已有下载好的镜像: $img"
  else
    c_ok "下载: $url"
    curl -fL --retry 3 -C - -o "$img" "$url"
  fi
  [ "$(stat -c%s "$img")" -gt 100000000 ] || die "镜像下载不完整（$(stat -c%s "$img") 字节）"
  unsquashfs -s "$img" >/dev/null 2>&1 || die "下载的镜像不是有效的 squashfs"

  c_ok "解包到 $ROOTFS_DIR（约 2.5GB，需要几分钟）..."
  unsquashfs -f -no-progress -d "$ROOTFS_DIR" "$img"
  rm -f "$img"
  c_ok "RootFS 就绪"
}

step_config() {
  section "3/7 写入 FEX 配置（RootFS 绝对路径）"
  mkdir -p "$(dirname "$FEX_CONFIG")"
  python3 - "$FEX_CONFIG" "$ROOTFS_DIR" <<'PY'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
    except Exception:
        pass
cfg.setdefault("Config", {})["RootFS"] = root
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("  已写入:", path)
PY
  c_ok "配置完成（注意：RootFS 必须写绝对路径，写名字解析不了）"
}

step_wine() {
  section "4/7 把 x86-64 Wine 放进 RootFS"
  if [ -x "$ROOTFS_DIR/usr/lib/wine/wine64" ]; then
    c_ok "Wine 已存在，跳过"
    return
  fi
  local suite
  suite=$(grep -m1 '^VERSION_CODENAME=' "$ROOTFS_DIR/etc/os-release" | cut -d= -f2- | tr -d '"')
  [ -n "$suite" ] || die "读不到 RootFS 的发行版代号"
  c_ok "RootFS 发行版代号: $suite —— 解析 wine 依赖闭包（可能需要几分钟）..."
  python3 "$SCRIPT_DIR/lib/resolve-wine-deps.py" \
    --rootfs "$ROOTFS_DIR" \
    --suite "$suite" \
    --cache "$CACHE_DIR/debs" \
    --packages wine64 libwine wine64-preloader
  [ -x "$ROOTFS_DIR/usr/lib/wine/wine64" ] || die "Wine 安装失败"
  c_ok "Wine 已放入 RootFS"
}

step_prefix() {
  section "5/7 准备 wine 前缀、Z: 合成根、system32 链接"

  # Z: 合成根 —— wine 默认把 Z: 当 "/"，但 FEX 不会重定向"符号链接指进 rootfs"的
  # 路径；所以给 Z: 做一个合成根：系统目录指进 rootfs，用户目录指宿主。
  mkdir -p "$ZROOT"
  local d
  for d in usr lib lib64 bin sbin etc var opt root boot; do
    [ -e "$ROOTFS_DIR/$d" ] && ln -sfn "$ROOTFS_DIR/$d" "$ZROOT/$d"
  done
  for d in home media mnt srv tmp run; do
    [ -e "/$d" ] && ln -sfn "/$d" "$ZROOT/$d"
  done

  # 前缀骨架 + 盘符
  mkdir -p "$PREFIX/dosdevices" "$PREFIX/drive_c/windows/system32" "$PREFIX/drive_c/apps"
  ln -sfn ../drive_c "$PREFIX/dosdevices/c:"
  ln -sfn "$ZROOT" "$PREFIX/dosdevices/z:"

  # wine 的 PE 模块链接进 system32（wine 先查这里；否则找不到 kernel32）
  local w="$ROOTFS_DIR/usr/lib/x86_64-linux-gnu/wine" f n=0
  if [ -d "$w/x86_64-windows" ]; then
    for f in "$w"/x86_64-windows/*; do
      [ -e "$f" ] || continue
      ln -sfn "$f" "$PREFIX/drive_c/windows/system32/"
      n=$((n + 1))
    done
  fi
  # zlib1.dll：wine 自己找不到它（它在 mingw 工具目录里）
  local z
  for z in "$ROOTFS_DIR"/usr/*-w64-mingw32/lib/zlib1.dll; do
    if [ -e "$z" ]; then
      ln -sfn "$z" "$PREFIX/drive_c/windows/system32/zlib1.dll"
      break
    fi
  done
  c_ok "system32 链接: $n 个模块"
}

step_wineboot() {
  section "6/7 初始化 wine 前缀（首次约 1-2 分钟）"
  if [ -s "$PREFIX/system.reg" ]; then
    c_ok "前缀已初始化，跳过"
    return
  fi
  WINEPREFIX="$PREFIX" LANG=C.UTF-8 FEXBash -c '/usr/lib/wine/wine64 wineboot' 2>&1 | tail -5 || true
  [ -s "$PREFIX/system.reg" ] || die "wineboot 没有完成（看上面输出）"
  c_ok "前缀初始化完成"
}

step_desktop() {
  section "7/7 安装 fex-wine 命令与桌面项（双击 .exe）"
  mkdir -p "$BIN_DIR" "$DESKTOP_DIR"
  install -m 755 "$SCRIPT_DIR/files/fex-wine" "$WRAPPER"
  sed "s|@WRAPPER@|$WRAPPER|g" "$SCRIPT_DIR/files/fex-wine.desktop" >"$DESKTOP"
  chmod 644 "$DESKTOP"

  # 自引用符号链接会让「应用列表」出现几十个重复图标（桌面缓存递归展开导致），
  # 检测到就只警告、不擅自移动用户的文件。
  local loop="" l
  while IFS= read -r -d '' l; do
    if [ "$(readlink -f -- "$l" 2>/dev/null)" = "$(readlink -f -- "$DESKTOP_DIR")" ]; then
      loop="$l"
      break
    fi
  done < <(find "$DESKTOP_DIR" -maxdepth 1 -type l -print0 2>/dev/null)

  if [ -n "$loop" ]; then
    c_warn "发现自引用符号链接: $loop"
    c_warn "它会让「应用列表」里出现大量重复图标。建议移走："
    c_warn "  mv \"$loop\" ~/applications.symlink-backup"
    c_warn "（本次跳过 update-desktop-database）"
  else
    have update-desktop-database && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  fi

  if have xdg-mime; then
    xdg-mime default fex-wine.desktop "$MIME_EXE" 2>/dev/null || true
    xdg-mime default fex-wine.desktop "$MIME_EXE_LEGACY" 2>/dev/null || true
  else
    c_warn "没有 xdg-mime，跳过 .exe 关联"
  fi
  c_ok "命令: $WRAPPER"
  c_ok "桌面项: $DESKTOP"
}

step_verify() {
  section "验证"
  local arch
  arch=$(FEXBash -c 'uname -m' 2>/dev/null | tr -d '\r' || true)
  [ "$arch" = "x86_64" ] || die "FEX 客户机自检失败（uname -m 返回 '$arch'）"
  c_ok "FEX 客户机: x86_64 ✅"

  local ver
  ver=$(WINEPREFIX="$PREFIX" LANG=C.UTF-8 FEXBash -c '/usr/lib/wine/wine64 --version' 2>/dev/null | tail -1 || true)
  case "$ver" in
    wine-*) c_ok "Wine: $ver ✅" ;;
    *) die "Wine 自检失败（返回 '$ver'）" ;;
  esac

  echo
  c_ok "全部完成 🎉"
  cat <<EOF

用法：
  · 文件管理器里双击任何 .exe → 用 FEX + Wine 打开
  · 命令行: $WRAPPER 程序.exe [参数]
  · 控制台程序会自动开终端窗口；日志在 ~/.fex-wine.log

限制：只支持 64 位 Windows 程序；性能为「能用」级（老/简单程序合适，大游戏别想）。
卸载：./install.sh --uninstall（加 --purge 连 FEX 包一起清）
EOF
}

do_check() {
  section "状态检查（只读，不做修改）"
  printf '%-22s %s\n' "架构" "$(uname -m)"
  printf '%-22s %s\n' "页大小" "$(getconf PAGESIZE)"
  printf '%-22s %s\n' "CPU 等级" "$(detect_cpu_tier 2>/dev/null || echo '不满足')"
  if dpkg -s fex-emu-armv8.2 fex-emu-binfmt64 >/dev/null 2>&1 || \
     dpkg -s fex-emu-armv8.0 fex-emu-binfmt64 >/dev/null 2>&1 || \
     dpkg -s fex-emu-armv8.4 fex-emu-binfmt64 >/dev/null 2>&1; then
    printf '%-22s %s\n' "FEX 包" "已安装 ✅"
  else
    printf '%-22s %s\n' "FEX 包" "未安装 ❌"
  fi
  printf '%-22s %s\n' "binfmt" "$(ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -i '^FEX' | tr '\n' ' ')"
  printf '%-22s %s\n' "RootFS" "$([ -x "$ROOTFS_DIR/usr/bin/true" ] && echo "✅ $ROOTFS_DIR" || echo '❌ 缺失')"
  printf '%-22s %s\n' "FEX 配置" "$([ -s "$FEX_CONFIG" ] && echo "✅ $FEX_CONFIG" || echo '❌ 缺失')"
  printf '%-22s %s\n' "Wine" "$([ -x "$ROOTFS_DIR/usr/lib/wine/wine64" ] && echo '✅ 已放入' || echo '❌ 缺失')"
  printf '%-22s %s\n' "wine 前缀" "$([ -s "$PREFIX/system.reg" ] && echo '✅ 已初始化' || echo '❌ 缺失')"
  printf '%-22s %s\n' "Z: 合成根" "$([ -L "$PREFIX/dosdevices/z:" ] && echo "✅ -> $(readlink "$PREFIX/dosdevices/z:")" || echo '❌ 缺失')"
  printf '%-22s %s\n' "system32 链接" "$(find "$PREFIX/drive_c/windows/system32" -maxdepth 1 -type l 2>/dev/null | wc -l) 个"
  printf '%-22s %s\n' "fex-wine 命令" "$([ -x "$WRAPPER" ] && echo "✅ $WRAPPER" || echo '❌ 缺失')"
  printf '%-22s %s\n' "桌面项" "$([ -f "$DESKTOP" ] && echo '✅' || echo '❌ 缺失')"
  printf '%-22s %s\n' ".exe 关联" "$(xdg-mime query default "$MIME_EXE" 2>/dev/null || echo '?')"
  echo
  if [ -s "$PREFIX/system.reg" ]; then
    local arch
    arch=$(FEXBash -c 'uname -m' 2>/dev/null | tr -d '\r' || true)
    printf '%-22s %s\n' "客户机自检" "${arch:-失败}"
  fi
}

do_uninstall() {
  local purge="${1:-no}"
  section "卸载"
  echo "将删除："
  echo "  $WRAPPER"
  echo "  $DESKTOP"
  echo "  $PREFIX          (wine 前缀)"
  echo "  $ZROOT           (Z: 合成根)"
  echo "  $ROOTFS_DIR      (x86-64 RootFS，约 2.5GB)"
  echo "  $FEX_CONFIG"
  read -r -p "确认卸载？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"

  rm -f "$WRAPPER" "$DESKTOP"
  have update-desktop-database && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  rm -rf "$PREFIX" "$ZROOT" "$ROOTFS_DIR" "$FEX_CONFIG"
  rmdir "$HOME/.fex-emu" 2>/dev/null || true

  if [ "$purge" = "purge" ]; then
    as_root apt-get remove --purge -y \
      fex-emu-armv8.0 fex-emu-armv8.2 fex-emu-armv8.4 \
      fex-emu-binfmt32 fex-emu-binfmt64 2>/dev/null || true
    as_root add-apt-repository -r -y ppa:fex-emu/fex 2>/dev/null || true
    as_root apt-get update 2>/dev/null || true
    c_ok "FEX 的 apt 包与 PPA 已清理"
  else
    c_ok "已卸载（FEX 的 apt 包保留，可加 --purge 一并清理）"
  fi
}

case "${1:-}" in
  "" | --install)
    preflight
    step_apt
    step_rootfs
    step_config
    step_wine
    step_prefix
    step_wineboot
    step_desktop
    step_verify
    ;;
  --check) do_check ;;
  --uninstall) do_uninstall ;;
  --purge) do_uninstall purge ;;
  -h | --help) usage ;;
  *) die "未知参数: $1（用 --help 看用法）" ;;
esac
