# Third-party notices / 第三方组件声明

`dsh-mac-portable` 自身以 **MIT** 发布（见 `LICENSE`）。本文件汇总**构建产物**
（`DSH.app`、zip、dmg）中包含的第三方组件、许可证与获取对应源码的方式，供再分发时
随附。仓库本身不含这些组件的字节，它们由 `scripts/fetch-runtime.sh` 与
`scripts/fetch-dsh.sh` 在构建时从公开源下载。

版本号以构建时的 `build/BUILD-INFO.txt` 和产物内 `package.json` 为准；下表按
v0.1.0 构建实际解析到的版本填写（`@deepseek-ai/dsh@next` 会随上游更新而变化）。

| 组件 | 版本 | 许可证 | 在产物中的位置 |
| --- | --- | --- | --- |
| Node.js (darwin-x64) | 22.18.0 | MIT（含其自带第三方声明） | `Contents/Resources/runtime/node/` |
| npm（随 Node 分发） | 10.x | Artistic-2.0 | 同上，仅构建期使用 |
| `@deepseek-ai/dsh` 及其依赖树 | `@next`（构建时 0.2.1-rc.3） | 以 MIT 为主，详见 §4 | `Contents/Resources/runtime/node_modules/` |
| `sherpa-onnx-darwin-x64` | 2.0.0 | Apache-2.0 | `.../node_modules/sherpa-onnx-darwin-x64/` |
| `@img/sharp-libvips-darwin-x64` | 1.3.4 | LGPL-3.0-or-later | `.../node_modules/@img/sharp-libvips-darwin-x64/` |
| Electron / Chromium | 未打包 | — | 无（界面用系统浏览器） |

许可证全文随压缩包放在 **zip 根目录**（与 `DSH.app` 同级，不在 `.app` 内）：
`LICENSES/Apache-2.0.txt`、`LICENSES/LGPL-3.0.txt`。DMG 卷内同样附带。

---

## 1. Node.js — MIT

- 项目：<https://nodejs.org/>，源码 <https://github.com/nodejs/node>
- 版权：Copyright Node.js contributors，部分代码 Copyright Joyent, Inc. 及其他人
- 许可证：MIT。产物内全文见
  `DSH.app/Contents/Resources/runtime/node/LICENSE`，该文件同时列出 Node 内嵌的
  V8、OpenSSL、libuv、zlib、c-ares、ICU 等第三方组件及其许可证。
- 本项目未修改 Node 的任何字节，只把它原样复制进 bundle。

## 2. Electron / Chromium — 未打包

本应用是纯 shell launcher：它启动内置的 Node 运行时，再用系统默认浏览器打开
本地 Web UI（`open` / `NSWorkspace`），**不包含 Electron、Chromium、CEF 或任何
浏览器内核**。因此不产生 Chromium/Electron 的再分发义务，也没有需要披露的
`LICENSES.chromium.html`。若未来改为打包 Electron，必须同时补齐其 BSD-3-Clause
等许可证文本与 Chromium 的第三方声明。

## 3. sherpa-onnx — Apache-2.0（已修改，§4(b) 声明）

- 包：`sherpa-onnx-darwin-x64@2.0.0`（<https://www.npmjs.com/package/sherpa-onnx-darwin-x64>）
- 上游：<https://github.com/k2-fsa/sherpa-onnx>，Copyright 2022-2024 k2-fsa
- 许可证：Apache License 2.0，全文见 `LICENSES/Apache-2.0.txt`

**修改声明（Apache-2.0 §4(b)）**

> `sherpa-onnx.node` was modified by dsh-mac-portable: the Mach-O
> `LC_BUILD_VERSION` `minos` field was lowered from `15.0.0` to `11.0.0` so the
> binary can load on macOS Big Sur. Exactly four bytes in the load command were
> changed; no code, symbol or resource was touched. The change is applied at
> build time by `scripts/patch-sherpa-minos.py`, which keeps a
> `sherpa-onnx.node.minos-backup` copy of the original next to the patched file.
> The unmodified package is available from npm at the URL above; its source is
> the upstream repository at the matching release tag.

这是本项目的**第一处修改**。上游若在其发行物中附带 `NOTICE`，应一并保留；本包
未提供独立 `NOTICE` 文件。

## 4. 依赖树中的其余包（约 614 个）

`@deepseek-ai/dsh` 的 npm 依赖树经审计（`npm ls --all` + `package.json` 的
`license` 字段）全部为宽松/开放许可证，没有 `UNLICENSED`：

| 许可证 | 包数 |
| --- | --- |
| MIT | 527 |
| Apache-2.0 | 53 |
| BSD-3-Clause | 15 |
| ISC | 10 |
| MPL-2.0 | 2 |
| BSD-2-Clause | 2 |
| LGPL-3.0-or-later | 1（sharp-libvips，见 §5） |
| Python-2.0 | 1 |
| Unlicense | 1 |
| 0BSD | 1 |
| MIT OR CC0-1.0 | 1 |

- 绝大多数包在 `node_modules/<pkg>/` 内自带 `LICENSE`/`COPYING`，随 bundle 原样保留；
  约 26 个包未附带许可证文本，但其 `package.json` 已声明上述许可证。
- MIT / ISC / BSD / 0BSD / Unlicense / CC0 只要求保留版权与许可声明，不要求随二进制
  附全文；`LICENSES/Apache-2.0.txt` 覆盖 53 个 Apache-2.0 包的 §4(a) 义务。
- 两个 **MPL-2.0** 包未被修改，按 MPL-2.0 §3.2 只需保留声明；若你修改了它们，必须
  公开修改后的源码。
- `Python-2.0` 包为构建期工具，不进入运行时路径。
- `@deepseek-ai/dsh` 本身为 **MIT**，Copyright (c) 2026 DeepSeek；其许可证文本位于
  `node_modules/@deepseek-ai/dsh/LICENSE`（若包内未附带，则以 npm registry 上的
  `license: MIT` 声明为准，全文见 <https://opensource.org/license/mit>）。

### 4.1 前端 polyfill（第二处修改）

`@deepseek-ai/dsh-web-frontend/dist/index.html` 在构建时被注入约 33 行
`Promise.withResolvers` polyfill（兼容 macOS Big Sur 的 Safari 16.x）。这是对 MIT
许可文件的修改：上游版权与许可声明原样保留，修改事实在此披露，不暗示官方原样产物。
注入逻辑在 `scripts/build-launcher.sh` 中，可用
`grep -c withResolvers .../dist/index.html` 复核。

## 5. libvips（经 `@img/sharp-libvips-darwin-x64`）— LGPL-3.0-or-later

- npm 包：`@img/sharp-libvips-darwin-x64@1.3.4`
- 打包脚本：<https://github.com/lovell/sharp-libvips>
- 上游库：libvips，<https://github.com/libvips/libvips>（源码与 release tarball）
- 许可证：GNU Lesser General Public License v3.0 or later，全文见
  `LICENSES/LGPL-3.0.txt`

`sharp` 通过动态链接的 `libvips` 处理图片；本项目**没有修改** libvips，只把 npm
包原样打包。按 LGPL-3.0 §4 履行如下义务：

1. **许可证副本**：`LICENSES/LGPL-3.0.txt` 随 zip/dmg 提供。
2. **对应源码（source offer）**：libvips 的完整对应源码可从
   <https://github.com/libvips/libvips> 的相应 release tag 获取，
   `@img/sharp-libvips-darwin-x64` 的打包脚本与补丁见
   <https://github.com/lovell/sharp-libvips>。本项目及构建者承诺：自收到二进制之日起
   **三年内**，任何第三方均可通过
   <https://github.com/fys413/dsh-mac-portable/issues> 免费索取对应源码的副本
   （仅收取介质/传输成本）。
3. **可替换/重链接（relinking）**：libvips 以动态库形式位于
   `DSH.app/Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64/lib/`
   （`libvips-cpp.*.dylib`、`libglib-2.0.*.dylib` 等）。`node_modules/` 是未修改的
   npm 安装树，`sharp` 在运行时 `dlopen` 这些库，因此你可以：
   1. 用兼容 ABI 的自建 libvips 替换同名 `.dylib`；
   2. 重新做 ad-hoc 签名：
      `codesign --force --deep --sign - DSH.app`；
   3. 重新启动 App 验证。
   无需重新编译本项目或上游 DSH。
4. 若你修改了 libvips 本身，必须按 LGPL-3.0 §4 公开修改后的源码。

## 6. 本项目自身 — MIT

`make.sh`、`scripts/*`、`verify.sh`、`docs/*`、`README.md`、`NOTICE.md`、
`BRAND.md`、`CHANGELOG.md`、本文件与 `LICENSES/` 下的汇编版权归
Copyright (c) 2026 dsh-mac-portable contributors，以 MIT 发布（全文见 `LICENSE`）。
`Contents/MacOS/DSH` 与 `Contents/Info.plist` 是 `scripts/build-launcher.sh` 的生成物，
同样以 MIT 发布。

## 7. 如何复核

```sh
# 产物内的许可证文本
unzip -l dist/DSH-Portable-*-macos11-x64.zip | grep -E 'LICENSES/|THIRD_PARTY'
# 修改声明
grep -n 'minos' THIRD_PARTY_NOTICES.md
# libvips 动态库与许可证
otool -L build/DSH.app/Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64/lib/*.dylib
```

本文件不是法律意见；正式发布前请结合 `docs/COMPLIANCE.md` 自行复核。
