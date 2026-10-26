# 合规说明（Compliance notes）

本文件记录构建产物中**已知的三处许可证/披露缺口**、修法，以及本地可执行的检查清单。它不是法律意见；发布前请自行复核。

背景：上游 DSH 以 **MIT** 发布（`@deepseek-ai/dsh` 的 `package.json` 声明 MIT，Copyright (c) 2026 DeepSeek），其 npm 依赖 614 个包经审计全部为宽松/开放许可证：MIT 527、Apache-2.0 53、BSD-3-Clause 15、ISC 10、MPL-2.0 2、BSD-2-Clause 2、LGPL-3.0-or-later 1、Python-2.0 1、Unlicense 1、0BSD 1、MIT OR CC0 1；0 个 `UNLICENSED`。其中 26 个包（4.2%）缺许可证文本文件。

> 仓库本身（A 档）不包含任何上游代码或二进制，因此本文的缺口只在**你构建并分发 `.app`/zip 时**适用。仅克隆仓库不触发再分发义务。

## 1. `sherpa-onnx.node` 被修改（Apache-2.0 §4(a) / §4(b)）

**缺口**：`scripts/patch-sherpa-minos.py` 把 `sherpa-onnx.node` 的 `LC_BUILD_VERSION.minos` 从 `15.0.0` 改为 `11.0.0`。该包为 **Apache-2.0**，而分发目录中既没有 `LICENSE` 也没有 `NOTICE` 文件。Apache-2.0 §4(a) 要求向接收者提供许可证副本，§4(b) 要求对修改过的文件作出显著修改声明。

**影响**：所有分发的 `.app`、zip、dmg。

**修法**（二选一，推荐 A）：

A. 构建后把许可证随二进制一起放进 bundle：

```sh
SHERPA=build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64
curl -fsSL -o "$SHERPA/LICENSE" \
  https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/LICENSE
cat > "$SHERPA/NOTICE" <<'EOF'
sherpa-onnx
Copyright 2022-2024 k2-fsa (https://github.com/k2-fsa/sherpa-onnx)
Licensed under the Apache License, Version 2.0.

MODIFIED by dsh-mac-portable: the Mach-O LC_BUILD_VERSION minos field of
sherpa-onnx.node was lowered from 15.0.0 to 11.0.0 for macOS Big Sur
compatibility. No other bytes were changed. See scripts/patch-sherpa-minos.py.
EOF
```

B. 若改走 B 档（随仓库分发二进制），把上述 `LICENSE`/`NOTICE` 一并纳入发布物，并在 Release notes 写明修改。

**验证**：

```sh
test -s build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64/LICENSE && echo LICENSE-OK
test -s build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64/NOTICE && echo NOTICE-OK
grep -q "MODIFIED by dsh-mac-portable" build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64/NOTICE && echo DISCLOSURE-OK
```

## 2. libvips 的 LGPL-3.0（许可证文本 + 源码要约）

**缺口**：`@img/sharp-libvips-darwin-x64@1.3.4` 以 **LGPL-3.0-or-later** 分发，但包内没有 LGPL 文本，也没有源码获取途径。LGPL 允许随专有程序一起分发动态库，但要求：提供许可证副本、告知用户如何替换该库，并提供对应源码（或书面要约）。

**影响**：所有分发的 `.app`、zip、dmg（`sharp` 用于图片处理，属 DSH 运行时依赖）。

**修法**：

1. 在 bundle 内附 LGPL-3.0 全文：

```sh
LIBVIPS=build/DSH.app/Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64
curl -fsSL -o "$LIBVIPS/LICENSE" https://www.gnu.org/licenses/lgpl-3.0.txt
```

2. 写一份 `THIRD-PARTY.md`（随 release 附件，不必进 git）说明：

```
libvips (via @img/sharp-libvips-darwin-x64 1.3.4)
License: LGPL-3.0-or-later
Source:  https://github.com/lovell/sharp-libvips
         https://github.com/libvips/libvips/tree/v8.15.x
Written offer: for three years, dsh-mac-portable contributors will provide the
corresponding source of libvips on request, at no charge beyond media cost.
Relinking: the shared library lives in
  Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64/lib/
and can be replaced with a compatible build; node_modules/ is an unmodified
npm install tree, so the library is dynamically loaded and replaceable.
```

3. 若你修改了 libvips 本身（本项目没有），必须公开修改后的源码。

**验证**：

```sh
test -s build/DSH.app/Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64/LICENSE && echo LGPL-TEXT-OK
otool -L build/DSH.app/Contents/Resources/runtime/node_modules/@img/sharp-libvips-darwin-x64/lib/*.dylib 2>/dev/null | head
```

## 3. 前端 polyfill 未披露

**缺口**：`@deepseek-ai/dsh-web-frontend/dist/index.html` 中注入了约 33 行的 `Promise.withResolvers` polyfill（为 Safari 16.6 提供缺失的 API）。这属于对 MIT 许可文件的修改：MIT 允许修改与再分发，但要求保留版权与许可声明；同时项目应当披露“这是修改过的上游文件”，避免用户误以为官方原样产物。

**修法**：在 `NOTICE.md` 与本文件披露（本仓库已做）；分发时确保：

```sh
# 上游版权/许可声明仍在
grep -q "MIT" build/DSH.app/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh-web-frontend/LICENSE 2>/dev/null || \
  echo "note: frontend package ships no LICENSE file; MIT terms come from @deepseek-ai/dsh"
# 确认 polyfill 存在（只读检查，不要改回）
grep -c "withResolvers" build/DSH.app/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html
```

若你要进一步修改前端，请在自己的 fork 中保留上游版权行，并在 `NOTICE.md` 增加“modified files”列表。

## 4. 依赖树中缺许可证文本的 26 个包

审计发现 614 个包中 26 个没有随包提供 `LICENSE`/`COPYING` 文件。这**不等于**这些包不允许再分发（其 `package.json` 均声明了宽松许可证），但严格合规的做法是补齐文本。可按需处理：

```sh
# 列出缺少许可证文件的包（在 build/node_modules 内运行）
node -e '
const fs=require("fs"),path=require("path");
const root=process.argv[1];
for (const d of fs.readdirSync(root)) {
  const dirs = d.startsWith("@") ? fs.readdirSync(path.join(root,d)).map(x=>path.join(d,x)) : [d];
  for (const p of dirs) {
    const dir=path.join(root,p);
    if (!fs.existsSync(path.join(dir,"package.json"))) continue;
    const hits=fs.readdirSync(dir).filter(f=>/^(LICEN[CS]E|COPYING|NOTICE)/i.test(f));
    if (!hits.length) console.log(p);
  }
}' build/node_modules
```

对缺文本的包，可从其 npm tarball 或上游仓库补 `LICENSE`；MIT/BSD/ISC 只要求保留声明，不是必须随二进制附全文，但附上更稳妥。

## 5. 发布检查清单

在打 tag、上传 Release 之前逐项确认：

- [ ] `./verify.sh` 通过（无明文 token、无 `node_modules`/`.asar`/Mach-O 入库）
- [ ] 构建产物内含 `sherpa-onnx` 的 `LICENSE` + `NOTICE`（含修改声明）
- [ ] 构建产物内含 `sharp-libvips` 的 `LICENSE`（LGPL-3.0 全文）
- [ ] Release notes 写明：非官方、MIT（本项目）、上游 DSH MIT © DeepSeek、两处修改（minos、polyfill）
- [ ] `THIRD-PARTY.md` 与源码要约链接随 Release 提供
- [ ] `BRAND.md` 的命名/标识检查通过（无 `ai.deepseek.*` bundle id、无官方图标）
- [ ] `.app` 未签名/未公证的事实已在下载页说明
- [ ] 没有把 `service.url`、`portable.raw.log`、token 或用户数据打进包

## 6. 与商标/品牌相关的合规

品牌规则单独写在 [../BRAND.md](../BRAND.md)：项目名使用缩写 `dsh-mac-portable`，显示名 `DSH Portable`，bundle id `com.example.dsh-mac-portable`，不附官方图标，必须保留“非官方”声明。商标合规与许可证合规是两件事，需同时满足。
