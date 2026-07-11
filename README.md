# fxpa -- iOS 包体积分析工具

`fxpa` 是一个用 Swift 编写的 iOS 包体积分析命令行工具，由原 Python/Shell 版本迁移而来。
一次 `xcodebuild archive` 编译，即可完成代码归因、资源分析、工程配置审计等全面检测，最终输出 JSON 数据与交互式 HTML 报告。

## 安装

```bash
brew install ChineseFirstKeng/fx-package-analyzer/fxpa
```

也可从源码构建：

```bash
swift build -c release
# 二进制位于 .build/release/fxpa
```

## 系统要求

- macOS 13+
- Xcode 15+（libclang 随 Xcode 内置，无需额外安装）

## 用法

```bash
fxpa check <路径> [选项]   # 分析包体积
fxpa init                   # 在当前目录生成默认 .package-check.json
```

`<路径>` 支持：工程目录 / `.xcworkspace` / `.xcodeproj` / `.app` / `.xcarchive`。

常用选项：

| 选项 | 说明 |
|---|---|
| `-c, --configuration <cfg>` | 编译配置（默认 Release） |
| `-t, --team <id>` | 签名 Team ID（10 位大写字母数字） |
| `-o, --output <dir>` | 输出目录（默认 `./package_analysis_<时间戳>`） |
| `--keep-build` | 保留编译产物 |
| `--enable-<模块>` / `--disable-<模块>` | 单独开关某个分析模块 |
| `--enable-all` / `--disable-all` | 全部开启/关闭 |

分析完成后，打开报告：

```bash
open <输出目录>/unified_report.html
```

## 分析模块

默认开启大部分模块，部分耗时模块需显式开启（`--enable-assets-car` / `--enable-thinning` / `--enable-objc-unused`）。

| 模块 | 说明 | 默认 |
|---|---|---|
| linkmap | LinkMap 代码段归因，按 Pod/模块拆分 | 开 |
| assets | `.app` 资源文件分析 | 开 |
| pod_resources | Pod 资源归属分析 | 开 |
| duplicates | 重复资源检测 | 开 |
| unused_resources | 无用资源检测 | 开 |
| build_config | 编译配置审计 | 开 |
| dead_code | 无用代码检测（Periphery + LinkMap） | 开 |
| swift_stdlib | Swift 标准库嵌入检测 | 开 |
| localization | 本地化语言审计 | 开 |
| assets_car | Assets.car 拆解（需 assetutil） | 关 |
| app_thinning | App Thinning 检测（需编译） | 关 |
| objc_unused | ObjC 未使用代码检测（需 libclang 编译） | 关 |

## 输出

分析结果输出到指定目录，包含：

- **JSON 数据**：各分析模块的中间数据文件，可供脚本二次处理
- **HTML 报告**：`unified_report.html`，交互式统一报告，含概览页、各模块详情与侧边栏导航

## 架构

```
Sources/
├── fxpa/                 可执行入口
└── FXPAKit/
    ├── CLI/              命令行（check 子命令 + init）
    ├── Config/           .package-check.json 与模块开关
    ├── Core/             Logger / Shell / 格式化 / Mach-O / JSON
    ├── Pipeline/         输入解析 / xcodebuild 编译 / Pod 映射 / 编排器
    ├── Models/           各分析器输出的 Codable 模型
    ├── Analyzers/        分析器协议与各模块实现
    ├── Report/           渲染器 / 适配器 / 统一报告生成
    └── Resources/        HTML/CSS/JS 模板与说明文件
```

分析器彼此解耦，仅通过编排器写出的 JSON 交换数据；报告层复用原始前端模板，在 Swift 端复刻数据结构。
