# 三合一状态栏 · UnifiedStatus

<p align="center">
  <img src="docs/app-icon-256.png" width="128" alt="三合一状态栏图标">
</p>

<p align="center">
  把输入法、Wi‑Fi 与电池状态整合进一个 macOS 菜单栏图标。
</p>

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Universal 2](https://img.shields.io/badge/Universal%202-Apple%20Silicon%20%2B%20Intel-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## 功能

- 一个图标同时显示输入法、Wi‑Fi 信号和电池余量。
- 两格 Wi‑Fi 时右侧圆点为空心；电量减少时圆环从右侧留空。
- 充电时显示闪电标记、预计充满时间和实时输入功率。
- 弹窗显示 Wi‑Fi、VPN、电池和当前输入法的详细状态。
- VPN 已连接时 Wi‑Fi 图标显示绿色。
- 点击“测速”打开节点测速页面。
- 鼠标离开后 3 秒自动收起弹窗。
- 首次启动提供原生状态栏图标隐藏向导，并自动检测完成情况。
- 支持登录时自动启动。
- Universal 2：同时支持 Apple Silicon 与 Intel Mac。

## 截图

| 状态面板 | 首次启动引导 |
| --- | --- |
| <img src="docs/dashboard.png" width="356" alt="状态面板"> | <img src="docs/onboarding.png" width="306" alt="首次启动引导"> |

## 系统要求

- macOS 13 Ventura 或更高版本
- Xcode Command Line Tools（仅从源码构建时需要）

## 安装

从仓库的 **Releases** 页面下载最新版 ZIP，解压后将 `三合一状态.app` 拖入“应用程序”文件夹并打开。

目前发布包采用本地签名，尚未经过 Apple Developer ID 公证。如果 Gatekeeper 阻止首次运行，请自行从源码构建，或仅在确认下载来源可信后通过“系统设置 → 隐私与安全性”允许打开。

## 从源码构建

```bash
git clone https://github.com/1362399368/UnifiedStatus.git
cd UnifiedStatus
chmod +x build.sh
./build.sh "$PWD/build/三合一状态.app" "$PWD/build/三合一状态.zip"
open "$PWD/build/三合一状态.app"
```

`build.sh` 会分别编译 `arm64` 与 `x86_64`，再合并为 Universal 2 应用。第二个参数为可选的 ZIP 输出路径。

## 使用方式

- 左键菜单栏图标：打开或关闭状态面板。
- 右键菜单栏图标：打开新手引导、切换登录启动、进入系统设置或退出应用。
- 第一次启动：根据引导隐藏系统自带的 Wi‑Fi、电池和输入法图标。

## 隐私

应用不包含分析、广告或账号系统，也不会上传 Wi‑Fi、电池、VPN 或输入法信息。所有状态读取都在本机完成。“测速”按钮只会在默认浏览器中打开第三方测速页面。

## 项目结构

- `App.swift`：状态读取、菜单栏图标、弹窗及交互。
- `Onboarding.swift`：首次启动引导、原生图标检测和登录启动管理。
- `Info.plist`：应用元数据与最低系统版本。
- `AppIcon.icns`：macOS 应用图标。
- `build.sh`：Universal 2 构建、签名与可选打包脚本。

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交前请确认应用能同时通过 `arm64` 与 `x86_64` 构建。

## 许可证

[MIT License](LICENSE)
