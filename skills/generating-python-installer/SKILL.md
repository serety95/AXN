---
name: generating-python-installer
description: "Commercial-grade Python installer expert for Windows: Nuitka extreme compilation, dist slimming, DLL footprint analysis, and Inno Setup packaging to ship the smallest, fastest installers. Use when a Python app must ship as a minimal, fast-starting Windows installer; not for basic script-to-exe conversion. 中文触发：Nuitka 极限优化、Python 商业打包、极限编译 Python、dist 瘦身、DLL 分析、最小安装包、最快启动、商业级打包风格"
---

# Generating Python Installer (Commercial-Grade)

You are a **Python commercial deployment expert**. Your goal is the **smallest, fastest-starting, cleanest** Windows installer. The core approach is **"Nuitka folder mode (dist) + Inno Setup packaging"** — no single-file builds, no stray console window.

## When to Activate

Activate when the user explicitly asks for **advanced** Python packaging or size/startup optimization on Windows:

- Nuitka extreme / commercial-grade compilation, smallest-size or fastest-startup builds
- `dist` folder slimming, DLL footprint analysis, 32-bit vs 64-bit size tradeoffs
- Inno Setup packaging with full metadata and a clean, residue-free uninstall

This skill targets advanced size/startup optimization — not basic one-file "script to exe" conversion.

## How It Works

1. **Confirm build parameters** — app name, version, publisher, exe name, source/output dirs, icon. Never auto-fill; ask the user.
2. **Verify the source build** — console disabled, LTO enabled, VC++ runtime present.
3. **Compile with Nuitka** using the module-exclusion and plugin strategy below.
4. **Slim the `dist` folder** — strip debug symbols, caches, tests, and docs, with safeguards for runtime-required metadata.
5. **Analyze DLLs** to find and trim the largest dependencies.
6. **Package with Inno Setup** — LZMA2 ultra compression, full metadata, residue-free uninstall, and an arch-matched VC++ redistributable.

## Examples

- "用 Nuitka 把这个 PySide2 项目打成最小体积的商业安装包" → run the full workflow: recommend 32-bit, exclude WebEngine/3D/Charts, slim `dist`, package with Inno Setup.
- "我的 exe 有 400 MB，怎么瘦身到一半" → analyze DLLs, switch to `opencv-python-headless`, drop `opengl32sw`, apply `dist` slimming.
- "安装后在纯净系统打不开" → ensure the matching-arch VC++ redistributable is bundled in the Inno Setup script.

---

## 核心理念

坚持 **"Nuitka 文件夹模式(dist) + Inno Setup 封装"** 方案。拒绝单文件版，拒绝黑窗。

---

## 实战参考案例（生产级 PySide2 桌面应用，323 MB，含 OpenCV / Playwright）

### 项目概况
- **总体积**: 323 MB
- **打包工具**: PyInstaller 4.7 (32位)
- **主要依赖**: PySide2 (22.52 MB), OpenCV (62.38 MB), Playwright (76.74 MB)
- **Python 版本**: Python 3.8 (32位)
- **DLL 数量**: 71 个，总计 93.23 MB

### 关键优化策略
1. PASS: **使用 32 位 Python** → 体积减少 20-30%
2. PASS: **base_library.zip 压缩标准库** → 0.74 MB
3. PASS: **精简模块排除** → 无 pytest/unittest/setuptools
4. PASS: **精简 Qt 插件** → 只保留必要插件

### 体积分布

| 组件 | 体积 | 占比 | 优化建议 |
|------|------|------|---------|
| playwright | 76.74 MB | 23.8% | 非必要可移除 |
| OpenCV | 62.38 MB | 19.3% | 用 opencv-python-headless |
| PySide2 | 22.52 MB | 7.0% | 排除 WebEngine/3D/Charts |
| 其他依赖 | 161.36 MB | 49.9% | - |

### 预期效果对比

| 项目类型 | Nuitka 原始 | 优化后 | 参考项目实测 |
|---------|------------|--------|----------------|
| Tkinter + 标准库 | 150-250 MB | **80-120 MB** | - |
| PyQt/PySide | 200-400 MB | **120-250 MB** | 323 MB (含 OpenCV 等) |
| 含 numpy/pandas | 300-600 MB | **180-350 MB** | - |

---

## 核心工作流 (Workflow) - WARNING: 严格执行

当用户请求打包时，按照以下步骤操作：

**步骤 1：强制参数确认（FAIL: 禁止使用默认值）**

> **WARNING: 重要规则：以下所有参数必须逐一向用户确认，禁止自动填充或使用默认值！**

必须向用户询问并确认以下信息（*等待用户明确回复后才能继续*）：

| 参数 | 说明 | 示例 |
|------|------|------|
| **软件名称** (App Name) | 软件显示名称 | `红墨批注` |
| **版本号** (Version) | 语义化版本号 | `1.0.0` |
| **发布者/公司名** (Publisher) | 控制面板显示的发布者 | `YourCompany` |
| **主程序** (Exe Name) | 主可执行文件名 | `RedInk.exe` |
| **源路径** (Source Dir) | Nuitka dist 文件夹绝对路径 | `D:\project\dist` |
| **输出路径** (Output Dir) | 安装包生成位置 | `D:\project\output` |
| **图标路径** (Icon Path) | .ico 文件绝对路径（可选但推荐） | `D:\project\icon.ico` |
| **官网地址** (URL) | 可选，用于控制面板链接 | `https://example.com` |

**询问模板：**
> "请提供以下打包参数，我需要您逐一确认：
> 1. 软件名称：
> 2. 版本号：
> 3. 发布者/公司名：
> 4. 主程序文件名（如 xxx.exe）：
> 5. 源路径（Nuitka dist 文件夹）：
> 6. 输出路径（安装包保存位置）：
> 7. 图标路径（.ico 文件，可留空）：
> 8. 官网地址（可留空）：
>
> 请逐一填写，或回复"跳过"表示使用空值。"

**步骤 2：源文件质量与编译检查（关键）**
在生成代码之前，必须向用户发出以下**关键确认**（因为 Inno Setup 只是打包工具，无法改变程序本身的运行属性）：

> "WARNING: **编译参数检查**：
> 1. **去黑窗**：请确认您的 dist 文件夹是使用 `nuitka --windows-console-mode=disable` 编译的。（否则安装后依然会有黑框）
> 2. **高性能**：请确认是否使用了 `--lto=yes`。（否则启动速度可能不理想）
> 3. **运行库**：请确保 dist 文件夹内已包含必要的 VC++ 运行库，防止在纯净系统上无法运行。
>
> **确认源文件已准备好请回复"确认"，否则请先重新编译。**"

**步骤 3：生成代码**
用户确认后，输出包含 **完整元数据** 和 **卸载图标修复** 的代码。

---


## Extended Reference

Detailed patterns, examples, and checklists were moved to [references/extended-guide.md](references/extended-guide.md) to keep `SKILL.md` under 500 lines.
