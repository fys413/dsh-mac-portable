# 构建指南（macOS 11 Big Sur / Intel x64）

本文按顺序复现 `dsh-mac-portable` 的构建过程。每一步都给出**命令、预期结果、耗时和验证方式**；任何一步失败，先看 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，不要跳步。

> **非官方说明**：本项目不是 DeepSeek 官方项目，只提供构建脚本。构建产物中的 DSH 代码与全部依赖均由 npm 在构建时下载，仓库本身不含上游代码或二进制（A 档，见 [../README.md](../README.md)）。

## 0. 前置检查

| 项目 | 要求 | 检查命令 |
| --- | --- | --- |
| 系统 | macOS 11.x（Big Sur），Intel x64 | `sw_vers -productVersion`、`uname -m` → `x86_64` |
| 命令行工具 | Xcode Command Line Tools（提供 `python3`、`git`、`make`） | `xcode-select -p`、`python3 -V` |
| 磁盘 | ≥ 3 GB 空闲（下载 + 解压 + .app） | `df -h .` |
| 网络 | 能访问 nodejs.org 与 registry.npmjs.org（或配置代理） | `curl -I https://nodejs.org` |
| 解压工具 | `tar`（系统自带）、`curl`、`shasum` | `command -v curl tar shasum` |

Apple Silicon 机器不在支持范围内：`uname -m` 为 `arm64` 时脚本会拒绝执行（`fetch-runtime.sh` 强制 darwin-x64）。如在 M 系列机器上尝试，请使用 Rosetta 终端并自行承担风险。

```sh
git clone https://github.com/<your-account>/dsh-mac-portable.git
cd dsh-mac-portable
chmod +x scripts/*.sh verify.sh
```

`chmod` 是必要的：从 zip 下载的仓库可能丢失可执行位。

## 1. 下载并校验 Node.js 运行时

```sh
./scripts/fetch-runtime.sh
```

- 下载 `node-v22.18.0-darwin-x64.tar.gz`（49,404,650 字节），校验
  `9c8aa1e5ff5780b38cc1134e2263d84e2f4308eb84c02515e3af33936ca02cdc`。
- 解压到 `build/runtime/node/`，只保留 `bin/node`、`lib/node_modules/npm`、
  `LICENSE`、`README.md`。
- 预期耗时：1–3 分钟（视网络）。
- 验证：

```sh
build/runtime/node/bin/node -p 'process.version + " " + process.arch'
# v22.18.0 x64
```

可选参数：`--dest DIR`、`--proxy URL`、`--force`（忽略已有缓存重下）、`--verify-only`（只校验已有文件）。
退出码：`0` 成功，`1` 下载/校验/解压失败，`2` 用法错误。

**为什么固定 22.18.0**：这是官方 macOS 构建所用的大版本线；换版本可能改变 npm 解析结果，导致原生模块 ABI 不匹配。

## 2. 安装 DSH npm 包（`--ignore-scripts`）

```sh
./scripts/fetch-dsh.sh
# 或固定版本：
# DSH_VERSION=0.1.0 ./scripts/fetch-dsh.sh
```

脚本实际执行（`build/node_modules` 为前缀）：

```sh
build/runtime/node/bin/node build/runtime/node/lib/node_modules/npm/bin/npm-cli.js \
  install --prefix "$PWD/build/node_modules" "@deepseek-ai/dsh@next" \
  --os=darwin --cpu=x64 --ignore-scripts --no-audit --no-fund --loglevel=warn
```

- 预期耗时：5–15 分钟，磁盘约 735 MB。
- 产物：`build/node_modules/@deepseek-ai/dsh/lib/bin.js` 以及 600 多个依赖。
- 验证：

```sh
build/runtime/node/bin/node build/node_modules/@deepseek-ai/dsh/lib/bin.js --version
cat build/BUILD-INFO.txt
```

### 为什么必须 `--ignore-scripts`

1. **供应链**：`postinstall` 钩子可以执行任意代码；我们只需要文件，不需要安装脚本。
2. **平台正确性**：我们在 macOS 上为 darwin-x64 安装；如果让脚本运行，某些包会为**宿主**重新编译或下载二进制，产物就不再与目标平台一致。
3. **原生模块已预编译**：`sherpa-onnx`、`node-addon-*` 等 npm 包自带 `prebuilt/darwin-x64-*.node`，无需编译。

代价：极少数依赖会因缺少安装步骤而缺文件（例如某些包需要 `postinstall` 改路径）。本项目用到的包已验证不需要；如果 `--version` 报 `MODULE_NOT_FOUND`，先看 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的“原生模块/缺文件”一节。

### 为什么用 `@next`

`next` 是官方预发布 tag，macOS 便携构建按该 tag 验证。要可复现，请用 `DSH_VERSION=<确切版本>` 固定，并把版本号写进 release notes；`--ignore-scripts` 不改变版本解析。

## 3. 降低原生模块的 minos（Big Sur 兼容）

```sh
# 先看会改什么，不写入
./scripts/patch-sherpa-minos.py --dry-run \
  build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node

# 正式打补丁（自动备份为 *.minos-backup）
./scripts/patch-sherpa-minos.py \
  build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node
```

- 补丁只改 Mach-O `LC_BUILD_VERSION` 命令里的 `minos` 字段（4 字节），从 `15.0.0` 降到 `11.0.0`，不改代码段。
- 同一脚本支持 fat 二进制（按 slice 逐个处理）；遇到 `LC_CODE_SIGNATURE` 默认拒改，需显式 `--force`，因为改字节会让签名失效。
- 验证：

```sh
./scripts/patch-sherpa-minos.py --dry-run \
  build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node
# ... already at or below 11.0.0 ... nothing to do
```

- 退出码：`0` 成功（含“无事可做”），`1` 文件/格式/签名问题，`2` 参数错误。
- 备份文件 `*.minos-backup` 已被 `.gitignore` 忽略，**不要提交**。

> 这一步只针对 `sherpa-onnx.node`。如果构建报告 `node-addon-require-builtin` 也带 minos 15，可用同一脚本传入第二个路径：
> `./scripts/patch-sherpa-minos.py <path-a> <path-b>`。

## 4. 生成 DSH.app

```sh
./scripts/build-launcher.sh            # 完整 app：build/DSH.app
# 开发时快速迭代（不复制 735MB，产物不可分发）：
# ./scripts/build-launcher.sh --link --force
```

- 生成 `Contents/Info.plist`、`Contents/PkgInfo`、`Contents/MacOS/DSH`（POSIX sh），
  以及 `Contents/Resources/runtime/{node,node_modules}`。
- 关键 plist 值：`CFBundleIdentifier=com.example.dsh-mac-portable`、
  `LSMinimumSystemVersion=11.0`、显示名 `DSH Portable`（去品牌，见 [../BRAND.md](../BRAND.md)）。
- 验证：

```sh
plutil -lint build/DSH.app/Contents/Info.plist
sh -n build/DSH.app/Contents/MacOS/DSH
file build/DSH.app/Contents/Resources/runtime/node/bin/node   # Mach-O 64-bit x86_64
```

退出码：`0` 成功，`1` 构建/校验失败，`2` 用法错误，`3` 缺运行时或 npm 载荷，`4` 目标已存在且未加 `--force`，`5` 生成的 launcher 语法错误。

### 启动器行为

- 日志目录 `~/Library/Logs/DSH-Portable/`（权限 0700，文件 0600）：
  `portable.log`（已打码）、`portable.raw.log`（原始，仅调试）、`service.url`（含 token，勿外传）。
- 通过 FIFO 把 `token=…` / `Bearer …` 打码后才写入 `portable.log`。
- 单实例：`instance.lock` + `ps` 校验；重复启动只重新打开浏览器。
- 等待服务打印 URL，最长 `DSH_PORTABLE_WAIT_SECONDS`（默认 600 秒）。
- 浏览器顺序 Chrome → Edge → Brave → Firefox → Chromium → Vivaldi → Arc，可用
  `DSH_PORTABLE_BROWSER="Google Chrome"` 覆盖；Safari 排在最后（16 会白屏）。
- 退出码：`0` 正常退出，`1` 通用错误，`3` 运行时/载荷缺失，`4` 启动超时或提前退出，`5` 无法打开浏览器。

## 5. 冒烟测试

```sh
open build/DSH.app
sleep 5
tail -n 20 ~/Library/Logs/DSH-Portable/portable.log
```

- 首次启动 1–5 分钟（解压/索引/初始化），超时时间 600 秒。
- 正常标志：日志出现 `ready after Ns`，浏览器打开 `http://127.0.0.1:PORT/?token=…` 并显示界面。
- 关闭：结束启动器（`Cmd+Q` 关浏览器不会停服务；在终端 `kill <launcher pid>` 或用活动监视器结束 `DSH`）。

## 6. 打包与校验和

```sh
./scripts/make-dmg-or-zip.sh                # dist/*.zip + SHA256SUMS
./scripts/make-dmg-or-zip.sh --dmg          # 额外生成 .dmg（hdiutil）
```

- 产物：`dist/DSH-Portable-0.1.0-macos11-x64.zip`（约 237 MB）、可选 `.dmg`、`dist/SHA256SUMS`。
- 脚本会：拒绝含符号链接的 bundle（`--link` 的产物）、删除 `.DS_Store`、强制 `0755`、
  重开 zip 校验 `Contents/MacOS/DSH` 的可执行位、写 SHA256。
- 退出码：`0` 成功，`1` 打包失败，`2` 用法错误，`3` bundle 不完整，`4` 缺 `zip`/`hdiutil`，`5` 校验失败，`6` 含符号链接。
- **不要把 zip/dmg 提交进 git**：`.gitignore` 已忽略；GitHub 单文件上限 100 MiB，发布走 Release 附件或 Git LFS。

## 7. 仓库自检

```sh
./verify.sh
git status --porcelain   # 应为空
```

`verify.sh` 检查：所有脚本 `bash -n`、Python 语法、文件清单体积（< 5 MB）、无 `node_modules`/`.asar`/Mach-O、
无明文 token、Info.plist 品牌字段、README 非官方声明、大文件与构建产物未入库。

## 8. 可复现性说明

| 变量 | 是否固定 | 说明 |
| --- | --- | --- |
| Node.js | ✅ 版本 + SHA256 | `fetch-runtime.sh` 硬编码 |
| DSH 包 | ⚠️ 默认 `@next` | 用 `DSH_VERSION` 固定；npm registry 内容本身可变 |
| 其余依赖 | ❌ 未锁 | 无 `package-lock.json`；需要严格复现时自行 `npm shrinkwrap` 后审计 |
| zip 时间戳 | ❌ | `ditto`/`zip` 保留文件 mtime；字节级重现不保证 |
| 原生模块 minos | ✅ | `patch-sherpa-minos.py` 幂等 |

## 9. 清理重建

```sh
rm -rf build dist
./scripts/fetch-runtime.sh && ./scripts/fetch-dsh.sh && \
./scripts/patch-sherpa-minos.py build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node && \
./scripts/build-launcher.sh && ./scripts/make-dmg-or-zip.sh
```

以上命令全部在仓库目录内执行，不会修改系统目录之外的路径；`build/` 与 `dist/` 可随时删除重建。
