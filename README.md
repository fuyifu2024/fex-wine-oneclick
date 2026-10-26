# fex-wine-oneclick

在 ARM64 Ubuntu（树莓派 5 等）上一键装好 **FEX-Emu + x86-64 Wine**，让 Windows 的 `.exe` **双击就能打开**。

> 已在 Raspberry Pi 5（4GB）\+ Ubuntu 26.04 LTS (resolute, aarch64) 上实测通过。

## 它做了什么

1. 从官方 PPA 安装 **FEX-Emu**（x86/x86-64 → ARM64 用户态转译层），并注册 binfmt
2. 下载 **Ubuntu 24.04 的 x86-64 RootFS**（FEX 运行 x86-64 程序所需的环境）
3. 往 RootFS 里放入 **x86-64 版 Wine 9.x** 及其依赖闭包（从 Ubuntu 官方仓库取 amd64 包，无需 root）
4. 配好 **wine 前缀**、**Z: 盘合成根**、**system32 链接**（下面「为什么需要这些 hack」里解释）
5. 安装 `fex-wine` 命令 + 桌面项，把 `.exe` 关联到它

## 要求

- ARM64（aarch64）Ubuntu **24.04+**，推荐 26.04
- **4K 页大小的内核**：`getconf PAGESIZE` 必须输出 `4096`（16K / 64K 页的内核跑不了 FEX）
- CPU：**ARMv8.2+**（树莓派 5 的 Cortex-A76 满足；脚本会自动识别 ARMv8.0/8.2/8.4 档位）
- 约 **7GB 空闲磁盘**（RootFS 解包后约 2.5GB）
- 需要 **sudo**（安装 apt 包时使用）

## 安装

```bash
git clone https://github.com/fuyifu2024/fex-wine-oneclick.git
cd fex-wine-oneclick
./install.sh
```

首次运行会提示输入一次 sudo 密码；RootFS 下载约 500MB，解包后约 2.5GB。

## 使用

- **文件管理器里双击任何 `.exe`** → 用 FEX + Wine 打开
- 命令行：`~/.local/bin/fex-wine 程序.exe [参数]`
- 控制台程序会自动开一个终端窗口显示输出；图形程序直接开窗
- 脚本化：`FEX_WINE_NO_TERMINAL=1 fex-wine 程序.exe` 让控制台程序在当前终端里直接跑
- 日志：`~/.fex-wine.log`

## 限制

- **只支持 64 位 Windows 程序**（RootFS 里的 noble `wine64` 没有编 32 位支持）
- 性能是「能用」级：老程序、简单 GUI、2D 小游戏可以；3D 大游戏别想
- **反作弊游戏跑不了**（EAC / BattlEye / Ricochet 等），这是 Wine 和模拟层的通病
- 首次启动某个程序会比较慢（FEX 要 JIT 编译，之后有缓存）

## 为什么需要这些「hack」

FEX 的 RootFS 是**路径重定向**而不是 chroot，由此带来两个坑，仓库里的脚本都自动处理了：

1. **FEX 不会重定向「内核把符号链接解析进 rootfs `/` 子树」的路径。** wine 默认把 `Z:` 指向 `/`，于是所有 `Z:\usr\lib\...\wine\...dll` 都落到宿主机的 `/usr`（那里没有 wine）→ `could not load kernel32.dll`。
   解决：`~/.fex-zroot` **合成根** —— 把 rootfs 的 `/usr`、`/lib`、`/etc` 等和宿主的 `/home`、`/media` 等拼起来；wine 前缀的 `dosdevices/z:` 指向它。
2. wine 的 PE 模块优先从**前缀的 system32** 找。把 rootfs 里的 `x86_64-windows/*` 全部符号链接进 system32，另外补上 wine 自己找不到的 `zlib1.dll`（它在 mingw 工具目录里）。
3. 启动 exe 必须用 **`Z:\...` 的 Windows 路径形式**，否则 Unity 等引擎会把程序目录识别成 `unix/...`，报「找不到 `*_Data` 文件夹」。

## 检查 / 卸载

```bash
./install.sh --check        # 只检查状态，不做修改
./install.sh --uninstall    # 卸载本脚本装的东西（保留 FEX 的 apt 包）
./install.sh --purge        # 连 FEX 的 apt 包和 PPA 一起删
```

## 排错

| 现象 | 处理 |
|---|---|
| `could not load kernel32.dll` | 重新跑 `./install.sh`（会补齐前缀里的 system32 链接） |
| 双击没反应 / 闪退 | 看 `~/.fex-wine.log` 的最后几行 |
| 应用列表出现几十个重复图标 | `~/.local/share/applications/` 里有个自引用符号链接，把它移走（脚本会提示） |
| `FEX 要求 4K 页大小的内核` | 这台机器是 16K/64K 页内核，无法使用 FEX |
| 游戏报找不到 `*_Data` | 已由 wrapper 的 `Z:\` 路径处理；若仍出现，把日志发到 issue |

## English quickstart

One-click installer for **FEX-Emu + x86-64 Wine** on ARM64 Ubuntu (tested on Raspberry Pi 5 / Ubuntu 26.04). After installation, double-clicking a Windows `.exe` opens it via FEX + Wine.

Requirements: aarch64 Ubuntu 24.04+, **4K page size**, ARMv8.2+, ~7 GB free disk, sudo for apt. 64-bit Windows binaries only. Performance is "usable, not fast"; anti-cheat games will not work.

```bash
git clone https://github.com/fuyifu2024/fex-wine-oneclick.git
cd fex-wine-oneclick && ./install.sh
```

## 致谢

- [FEX-Emu](https://github.com/FEX-Emu/FEX) — ARM64 上的 x86/x86-64 用户态模拟器
- [Wine](https://www.winehq.org/) — Windows API 兼容层
- Ubuntu 官方仓库 / FEX RootFS 镜像站

## License

MIT
