# CHANGELOG

本项目从 **A 档**（只发自产脚本/补丁/文档，零上游字节）起步。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [Unreleased]

### Added
- **B 档一键构建**：根目录 `make.sh`（POSIX sh，`set -euo pipefail`，幂等）按序调用
  `fetch-runtime` → `fetch-dsh` → `patch-sherpa-minos` → `build-launcher` →
  `make-dmg-or-zip`，失败即停并打印步骤号、退出码与下一步提示；支持 `--skip-fetch`
  `--clean` `--no-sign` `--sign` `--dmg` `--version` `--bundle-id` `--proxy`。
- `scripts/build-launcher.sh`：`CFBundleIdentifier` 可配置（`--bundle-id`，默认
  `io.github.<user>.dsh-mac-portable`，拒绝含 `deepseek`）；`--version` 同时写入
  `CFBundleShortVersionString` 与 `CFBundleVersion`。
- 合规文件：`THIRD_PARTY_NOTICES.md`（Node MIT、sherpa Apache-2.0 + `minos 15.0 → 11.0`
  修改声明、libvips LGPL-3.0 源码要约与替换方法、其余依赖汇总）、`LICENSES/`
  （Apache-2.0 与 LGPL-3.0 全文）；`make-dmg-or-zip.sh` 把三者放进 zip 根目录并在
  重新打开 zip 时校验非空。
- CI：`.github/workflows/verify.yml`（`macos-13`；`bash -n` 全部脚本 → `./verify.sh` →
  只读 `./make.sh --help`；不跑完整构建）。
- `verify.sh`：新增 make.sh 选项/步骤顺序、bundle id 默认值与校验、许可证文本与 notices、
  CI 工作流检查；脚本清单扩到 make.sh 与全部构建脚本。

### 计划
- 把 `@next` 钉成精确版本 + `package-lock.json`；polyfill 改成 `patches/*.patch`
  并由 `apply-patches.sh` 幂等应用；GitHub Actions（`macos-13`）只出 artifact。
- 在真实 Big Sur 机器上跑一遍构建产物并记录结果（B 档代码目前只在 Windows 上做过静态校验）。
- 把 minos 与 Safari polyfill 两个问题反馈给上游。

## [0.1.0] — 2026-10-26

A 档首发。仓库内只有自产文本，**不含任何上游字节**。

### Added
- `README.md`：这是什么、非官方声明、构建前置、快速开始、目录说明、已知限制、
  官方获取指引；中文为主 + 英文摘要。
- `LICENSE`（MIT，Copyright (c) 2026 dsh-mac-portable contributors）、
  `NOTICE.md`（自产/上游归属、构建期第三方清单、两处修改声明、明确不含项）、
  `BRAND.md`（落实上游 `BRAND_GUIDELINES.md`：缩写命名、去品牌 bundle id、非官方声明）。
- `scripts/fetch-runtime.sh`：下载 Node **v22.18.0 darwin-x64**，校验
  SHA256 `9c8aa1e5ff5780b38cc1134e2263d84e2f4308eb84c02515e3af33936ca02cdc`，
  解压到 `build/runtime`；支持 `--verify-only` / `--proxy` / `--force`。
- `scripts/fetch-dsh.sh`：`npm install @deepseek-ai/dsh@next --os=darwin --cpu=x64
  --ignore-scripts` 到 `build/node_modules`；支持 `DSH_VERSION` 钉版本。
- `scripts/patch-sherpa-minos.py`：纯 Python 修改 Mach-O `LC_BUILD_VERSION.minos`
  （支持 thin/fat），**先备份原文件**，幂等，可 `--dry-run`。
- `scripts/build-launcher.sh`：生成 `DSH.app/Contents/MacOS/DSH`（POSIX sh）、
  `Info.plist`（`CFBundleIdentifier com.example.dsh-mac-portable`）、`PkgInfo`，
  并把 `build/runtime` 组装进 `Contents/Resources/`；支持 `--skeleton` / `--link`。
- `scripts/make-dmg-or-zip.sh`：打包 zip（排除 `.DS_Store`，保留 0755，附 `SHA256SUMS`），
  可选 `--dmg`（`hdiutil`）。
- `docs/BUILD.md`：逐步复现，含 `--ignore-scripts` 的理由、minos 补丁原理、
  Safari polyfill 的现状与产物校验命令。
- `docs/COMPLIANCE.md`：三处合规缺口与修法（sherpa Apache-2.0 §4(a)/4(b)、
  libvips LGPL-3.0 源码要约、polyfill 披露），附可直接复制的模板。
- `docs/TROUBLESHOOTING.md`：Safari 白屏、translocation/quarantine、native addon
  加载失败、启动慢/超时、端口与 token 问题。
- `verify.sh`：离线自检 —— `bash -n` 全部脚本、Python 语法、跟踪文件体积、
  无上游二进制/`node_modules`/`.asar`、无明文 token、品牌与"非官方"声明检查。
- `.gitignore`：`build/`、`dist/`、`*.dmg`、`*.zip`、`DSH.app/`、`node_modules/`、
  `.DS_Store`、`*.log` 等；`.gitattributes` 强制 LF，避免 macOS 上 CRLF 破坏脚本。

### Notes
- 产物实测参考：`.app` 734.7 MiB / 61,468 文件，zip 237.4 MiB，最大单文件
  143.6 MiB（`libreoffice-kit`）→ 超过 GitHub 100 MiB 单文件上限，**只能走 Releases**。
- 本仓库的构建步骤来自一次实际构建（macOS 目标、Windows 上交叉打包、只做静态校验）；
  完整构建链已在脚本中固化，但**尚未在真机 Big Sur 上跑过**，见 README §7。
