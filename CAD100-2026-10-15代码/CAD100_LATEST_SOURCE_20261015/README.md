# 出图100%（CAD-100）

面向批量 CAD 图框替换、图签字段更新和处理结果验收的 Windows 桌面工具。本次源码整理日期为 **2026-10-15**，包含保留原图签变换参数、图名/图号原属性、直白失败提示及统一信息/人员姓名保留与清空功能。构建脚本默认应用版本为 **2.1.0**；最终程序版本以实际构建参数为准。

本仓库用于团队内部协作和 Debug。仓库中不应出现客户项目图纸、未脱敏 DWG、处理输出、日志、凭据或本机配置。

## 本次源码包说明

- 此包为源码，不包含可直接启动的最新 EXE，也不混入旧试用程序压缩包。
- 图框和图签分别保留各自的原插入点、X/Y 缩放和旋转；不把 150.00001811 取整写成 150。
- 原属性几何保留主要针对可可靠读取的原本地图签中的图名、图号，不代表所有散文字、代理或外参结构均已验证。
- 保留严格验收与原始诊断；富文本重复指令问题未在本轮修复。
- 相关历史验证记录见 docs/validation；数据回放不能替代原生 AutoCAD 实际处理、保存重开验证。
- 使用正式授权服务和对应公钥构建；不得将私钥、激活码、用户数据库或客户原图提交到仓库。

[源码逻辑与开发边界](docs/SOURCE_ARCHITECTURE_20261015.md) · [原图签变换试用说明](docs/ORIGINAL_TITLE_TRANSFORM_TRIAL_20261014.md) · [直白失败提示说明](docs/PLAIN_FAILURE_MESSAGES_20261014.md)

## 主要能力

- 扫描模型空间和布局空间中的图框、图名、图号及图签字段。
- 按 A0、A1、A2及其加长规格匹配并替换图框。
- 支持常规块、XREF 图框及可明确识别边界的布局炸开图框。
- 批量更新项目统一信息、人员姓名和签字 DWG。
- 单张失败时跳过该文件，继续处理其他文件。
- 输出问题清单、处理记录和最终验收报告。
- 原始 DWG 永不覆盖；输出目录自动递增 V1.0、V2.0、V3.0……

## 仓库结构

```text
src/CadProcessingCore/   WinForms 处理核心与流程控制
src/Drawing100Wpf/       “出图100%”WPF 用户界面
engine/scripts/          AutoLISP 与 PowerShell 扫描、替换、验收脚本
engine/assets/           程序运行所需的分规格图框和图签块
templates/               原始新图框及图签模板
docs/                    使用、开发与问题反馈文档
build.ps1                本地编译和便携包生成脚本
```

## 运行条件

- Windows 10/11，64 位。
- .NET Framework 4.x。
- AutoCAD 2020 或更高版本，推荐 2021 以上。
- PowerShell 5.1。

程序会扫描 AutoCAD 标准安装目录和注册表，在 AutoCAD 2020–2027 中优先选择已安装的最高版本 `accoreconsole.exe`。这不是按每张 DWG 的保存版本逐张切换 Core。

## 编译

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 `
  -LicenseApiBaseUrl "https://你的授权服务地址" `
  -LicensePublicKeyPath "C:\部署配置\public_key.xml" `
  -AppVersion "2.1.0"
```

编译成功后，便携版位于：

```text
dist/CAD-100/
```

本项目当前直接使用系统自带的 .NET Framework C# 编译器，暂未依赖 NuGet 包。

## Debug 与提交要求

1. 从 `main` 创建修复分支，例如 `fix/layout-frame-detection`。
2. 修改后至少完成编译、目标 DWG 实测和最终验收报告检查。
3. 不得提交未脱敏的项目 DWG；需要复现文件时，先制作最小、脱敏样例。
4. Pull Request 中写明根因、修改范围、验证文件类型和验收结果。

具体说明参见 [开发与调试说明](docs/开发与调试说明.md) 和 [使用指南](docs/使用指南.txt)。
