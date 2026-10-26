# NOTICE

**本项目（dsh-mac-portable）是非官方项目。** 与 DeepSeek 及其任何关联实体没有隶属、
赞助或背书关系；项目名称、任何文档与任何构建产物都不代表官方立场。

This is an **unofficial** project. It is not affiliated with, endorsed by, or
sponsored by DeepSeek. "DeepSeek Harness" is a registered trademark of
DeepSeek; this project only uses the abbreviation "DSH" in its name.

---

## 1. 本仓库自产部分

| 范围 | 版权 | 许可 |
| --- | --- | --- |
| `scripts/*`、`verify.sh`、`docs/*`、`README.md`、`NOTICE.md`、`BRAND.md`、`CHANGELOG.md` | Copyright (c) 2026 dsh-mac-portable contributors | MIT（见 `LICENSE`） |
| `scripts/build-launcher.sh` 生成物：`Contents/MacOS/DSH`、`Contents/Info.plist` | 同上 | 同上 |
| `docs/BUILD.md` 中的 Safari polyfill 代码片段 | 同上 | 同上 |

自产部分全部由本项目作者编写，未复制上游源码。

## 2. 上游项目（不在本仓库中）

- 项目：DeepSeek Harness（命令行/桌面应用），仓库 <https://github.com/deepseek-ai/deepseek-harness>
- 许可：**MIT**，Copyright (c) 2026 DeepSeek
- 商标与品牌要求：上游 `BRAND_GUIDELINES.md`（摘要与落实方式见 `BRAND.md`）

本仓库**不包含**上游源码、上游 npm 包、`.asar`、前端 `dist/` 产物、任何 Mach-O 二进制、
任何 `.app` / `.zip` / `.dmg`。构建时所需的全部上游字节由 `scripts/fetch-dsh.sh` 在
**用户自己的机器上**从公开 npm registry 下载，不进入本仓库的 git 历史。

## 3. 构建时下载/安装的第三方组件（同样不在本仓库中）

| 组件 | 版本 | 许可 | 获取途径 |
| --- | --- | --- | --- |
| Node.js darwin-x64 | 22.18.0（SHA256 固定 `9c8aa1e5…02cdc`） | MIT（附其自带第三方声明） | <https://nodejs.org/dist/> |
| npm（随 Node 分发） | 随 22.18.0 | Artistic-2.0 | 同上 |
| `@deepseek-ai/dsh` 及其依赖树（约 614 包） | `@next` 或 `DSH_VERSION` 指定的精确版本 | MIT 为主，另含 Apache-2.0 / BSD-3-Clause / BSD-2-Clause / ISC / MPL-2.0 / LGPL-3.0-or-later / Python-2.0 / Unlicense / 0BSD | <https://registry.npmjs.org/> |

**这些组件不会被本仓库再分发**；再分发的许可义务由"构建产物"的发布者承担，
`docs/COMPLIANCE.md` 给出了逐项义务与可直接复制的模板。

## 4. 构建脚本对第三方所做的两处修改

这两处修改都发生在用户本机的构建产物里，本仓库不含被修改的文件本体：

1. `sherpa-onnx-darwin-x64/sherpa-onnx.node`：把 Mach-O `LC_BUILD_VERSION.minos`
   从 `15.0.0` 降到 `11.0.0`，使其能在 Big Sur 加载。该包为 **Apache-2.0**，
   §4(b) 要求对被修改文件给出显著修改声明（模板见 `docs/COMPLIANCE.md` §2）。
2. `@deepseek-ai/dsh-web-frontend/dist/index.html`：在 `<head>` 最前注入
   `Promise.withResolvers` polyfill（兼容 Big Sur 的 Safari 16.x）。该文件为 MIT，
   修改同样需要在产物里披露（模板见 `docs/COMPLIANCE.md` §4）。

另有一处**未修改**但需注意的组件：`@img/sharp-libvips-darwin-x64`
（**LGPL-3.0-or-later**）。动态链接分发时需附许可文本 + 源码获取途径/书面要约，
见 `docs/COMPLIANCE.md` §3。

## 5. 本仓库明确不包含

- `node_modules/`、`build/`、`dist/`、`DSH.app/`、`*.zip`、`*.dmg`、`*.asar`
- 任何 Mach-O 文件（`.node`、`.dylib`、可执行 `node`）
- 任何 token / 私钥 / 凭证（`verify.sh` 会扫描）
- 上游前端 HTML、上游 LICENSE 文本以外的上游文件

## 6. 商标

"DeepSeek Harness" 是 DeepSeek 的注册商标。本项目：

- 项目名只用缩写 **DSH**（`dsh-mac-portable`），不使用完整商标作为项目名；
- 应用名用 **DSH Portable**，`CFBundleIdentifier` 默认 `io.github.<user>.dsh-mac-portable`
  （由 `$DSH_BUNDLE_USER`/`$USER` 生成，可用 `--bundle-id` 覆盖；不含 `deepseek`）；
- 不使用官方图标/官方视觉素材；
- 在 README、应用内提示、发布说明中显式声明"非官方"。

描述性文字（例如 "built on DeepSeek Harness"）属于上游指南允许的用法，详见 `BRAND.md`。
