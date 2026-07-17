# AppGuard

`AppGuard` 是 iOS 越狱进程守护与性能优化插件源码工程。通过 SpringBoard hook 触发后台守护进程，对每个目标进程独立下发内存限制、Jetsam 优先级和 CPU Nice 调度策略，并可剥离 P_MEMSTAT_MANAGED 内核标记阻止系统自动覆盖。

## 功能概览

- 基本控制
  - 启用/关闭插件总开关，关闭时自动恢复所有进程默认状态。
  - 支持进程列表按 Nice/Jetsam 优先级排序。
  - 支持导入/导出/恢复配置，导出文件兼容 `.plist` 格式。
- 进程管理
  - 支持按包名或进程名添加目标进程，内置已安装 App 选择器（带搜索和图标）。
  - 每个进程独立编辑：活跃/非活跃内存限制、Jetsam 优先级、Nice 调度优先级、检测周期、备注名称。
  - 支持删除进程记录。
- 内核级对抗
  - 剥离系统托管（`P_MEMSTAT_MANAGED`）：阻止内核加回原有优先级。
  - 同时开启 `ELEVATED_INACTIVE` 非活跃提升保护，锁定 `PRIO_DARWIN_ROLE_UI_FOCAL`。
  - 高目标 Jetsam 值被内核拒绝时自动除以 10 二次下发（动态探测适配）。
- 后台守护进程
  - Darwin 通知 `com.axs.appguard/ApplyLimits` 触发即时生效（0.15s 防抖）。
  - 全局 1800s 定时器处理 `CheckInterval = 0` 的进程巡检。
  - 独立防并发工作队列，每次循环释放内存池，避免长期运行内存膨胀。
- 日志与状态
  - 守护进程日志实时输出到 `AppGuard.log`，支持按大小自动清空。
  - 设置面板实时显示每个进程的 PID、实际 Nice/Jetsam 值，1.5s 刷新。
  - 搜索栏支持按进程名或备注快速过滤。

## 运行时边界

- Tweak 仅 hook `SpringBoard.frontDisplayDidChange:`，不注入第三方进程。
- 守护进程以 root 权限运行，自保护优先级设为最高（Nice -20，Jetsam 999→210→21 降级探测）。
- 内存限制读写走 `memorystatus_control`，读取内核实际值做一致性校验并输出 `[内核]` 标记。
- 偏好读写绕过 `CFPreferences/ cfprefsd` 缓存，直接操作 `/var/mobile/Library/Preferences/com.axs.appguard.plist`。
- 兼容 `roothide` 无根路径转换（`jbroot()`），支持有根/无根/隐藏越狱三种环境。
- 日志文件限制读末尾 50KB，防止界面卡顿。

## 项目结构

```text
AppGuard/
├── .github/
│   └── workflows/
│       └── build.yml                                            # GitHub Actions 构建流程
├── daemon/
│   ├── main.m                                                   # 后台守护进程（内存限制/优先级下发/状态跟踪）
│   ├── daemon.entitlements                                      # 守护进程签名权限
│   └── Makefile                                                 # 守护进程 Tool 构建配置
├── prefs/
│   ├── AppGuardPrefs.h/.m                                       # 设置面板控制器（进程编辑/搜索/日志查看/配置导入导出）
│   ├── Resources/
│   │   ├── icon@2x.png / icon@3x.png / icon.png                # 设置入口图标
│   │   ├── Info.plist                                           # PreferenceBundle 信息配置
│   │   └── Root.plist                                           # 静态设置项（开关、排序、进程列表、日志）
│   └── Makefile                                                 # PreferenceBundle 构建配置
├── layout/
│   ├── DEBIAN/
│   │   └── postinst                                             # 安装后脚本（重启守护进程）
│   └── Library/
│       ├── LaunchDaemons/
│       │   └── com.axs.appguardd.plist                          # LaunchDaemon 注册（root 权限自启）
│       └── PreferenceLoader/
│           └── Preferences/
│               └── AppGuard.plist                               # 设置 App 入口注册
├── AppGuard.plist                                                # Tweak 过滤器（仅注入 SpringBoard）
├── Tweak.x                                                       # Logos hook：前台切换时通知守护进程
├── control                                                       # Debian 包元信息
├── Makefile                                                      # Tweak 构建配置（包含 prefs/daemon 子项目）
├── build.sh                                                      # 本地构建脚本（一键编译 rootful/rootless/roothide）
└── README.md                                                     # 项目说明
```

## 构建

本项目按 Theos 工程组织：

```bash
# 单版本构建
make package

# 一键编译 rootful + rootless + roothide
chmod +x build.sh && ./build.sh
```

Windows 环境通常缺少 Theos/`make`，建议在 macOS、Linux 或已配置 Theos 的构建环境中执行。

## 偏好域

- 偏好域：`com.axs.appguard`
- 偏好变更通知：`com.axs.appguard/ApplyLimits`
- 守护进程已处理进程状态文件：`com.axs.appguard.status.plist`
