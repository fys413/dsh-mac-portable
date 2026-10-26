# 故障排查（Troubleshooting）

按“症状 → 原因 → 处理 → 验证”组织。所有命令都在仓库根目录或 `.app` 内执行。日志默认在
`~/Library/Logs/DSH-Portable/`（`portable.log` 已打码，`portable.raw.log` 为原始输出，`service.url` 含 token）。

先做三件事再排查：

```sh
uname -m && sw_vers -productVersion        # 期望 x86_64 / 11.x
tail -n 50 ~/Library/Logs/DSH-Portable/portable.log
xattr -l build/DSH.app | head              # 是否有 com.apple.quarantine
```

---

## 1. Safari 打开后白屏 / 页面空白

**症状**：服务已就绪，Safari 显示空白页或一直转圈；控制台报 `Promise.withResolvers is not a function`。

**原因**：Big Sur 自带的 Safari 16 缺少 `Promise.withResolvers`。前端 `index.html` 里虽然注入了 33 行 polyfill，但 Safari 16 的 CSP/旧引擎仍可能在早期脚本加载阶段失败，导致整页白屏。官方发布说明也只承诺 Chrome 类浏览器。

**处理**：

```sh
# 用 Chrome（或 Edge/Brave/Firefox）打开
open -a "Google Chrome" "$(sed -n '1p' ~/Library/Logs/DSH-Portable/service.url)"
# 或让启动器默认用它
DSH_PORTABLE_BROWSER="Google Chrome" open build/DSH.app
```

**验证**：Chrome 地址栏出现 `http://127.0.0.1:<port>/?token=…` 且界面正常渲染。

> 不要为了 Safari 去改前端源码；那会偏离上游，也会让 `NOTICE.md` 的修改披露失效。

---

## 2. Gatekeeper 拦截 / 提示“已损坏”/ App Translocation

**症状**：
- 双击提示“无法打开，因为无法验证开发者”；
- 或提示“DSH.app 已损坏，应将其移到废纸篓”；
- 或从“下载”目录直接运行时，日志里的路径变成
  `/private/var/folders/.../AppTranslocation/...`，运行时找不到 `Resources`。

**原因**：产物未签名、未公证；macOS 对带 quarantine 属性的 App 还会做 App Translocation（在随机只读路径挂载），使相对路径与符号链接失效。

**处理**：

```sh
# 1) 去掉隔离属性（只对你自己构建/信任的产物做）
xattr -dr com.apple.quarantine build/DSH.app

# 2) 移到固定位置再运行，避免 translocation
mv build/DSH.app /Applications/DSH.app
open /Applications/DSH.app

# 3) 仍然报签名问题时，做 ad-hoc 重签（改了 minos 后尤其需要）
codesign --force --deep --sign - /Applications/DSH.app
```

**验证**：

```sh
codesign -dv /Applications/DSH.app 2>&1 | head -3   # 应显示 adhoc
spctl -a -vv /Applications/DSH.app 2>&1 | head -3   # 预期 rejected（未公证，属正常）
```

**说明**：本项目不做签名/公证；正式分发需要 Apple Developer ID，成本与流程不在范围内。

---

## 3. 原生模块报错（minos / 架构 / 签名）

**症状**（日志或终端）：

```
Error: dlopen(.../sherpa-onnx.node, 0x0002): tried: ...
  (mach-o file, but is an incompatible architecture)
```
或
```
... built for macOS 15.0 which is newer than running OS (11.x)
```
或
```
code signature invalid
```

**原因**：
- `minos` 仍是 15.0 → 第 3 步补丁没打或打错文件；
- 架构不符 → 用了 arm64 的 Node 或包；
- 改字节后签名失效 → 需要重签。

**处理**：

```sh
# 1) 看真实架构与 minos
file build/DSH.app/Contents/Resources/runtime/node/bin/node
#   期望：Mach-O 64-bit executable x86_64
file build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node

# 2) 补丁是否生效（dry-run 应显示 nothing to do）
./scripts/patch-sherpa-minos.py --dry-run \
  build/DSH.app/Contents/Resources/runtime/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node

# 3) 重签（只影响本地产物）
codesign --force --deep --sign - build/DSH.app
```

如果 `patch-sherpa-minos.py` 报 `LC_CODE_SIGNATURE present`，说明该二进制已签名；确认来源可信后加 `--force`，然后重签。

**验证**：重启 App，日志中不再出现 `dlopen`/`newer than running OS`；语音相关功能可用（实验性）。

---

## 4. 启动慢 / 一直等到超时（退出码 4）

**症状**：启动器弹出“server did not report a URL within 600s”，或终端退出码 `4`。

**原因**：
- 首次启动要解压/建索引，1–5 分钟属正常，机械硬盘或低配更久；
- 端口被占 / 上一次进程残留；
- `token=` 行没被识别（日志被截断或输出到 stderr 之外）；
- 运行时缺文件（`--ignore-scripts` 偶发缺包）。

**处理**：

```sh
# 1) 看进度与最后错误
tail -n 80 ~/Library/Logs/DSH-Portable/portable.log
tail -n 80 ~/Library/Logs/DSH-Portable/portable.raw.log

# 2) 清掉残留锁/进程
cat ~/Library/Logs/DSH-Portable/instance.lock 2>/dev/null
ps aux | grep -i "dsh" | grep -v grep
pkill -f "@deepseek-ai/dsh"        # 确认没有别的 DSH 在用

# 3) 加大等待时间（调试用）
DSH_PORTABLE_WAIT_SECONDS=1200 open build/DSH.app

# 4) 直接跑服务，看它到底输出什么
build/DSH.app/Contents/Resources/runtime/node/bin/node \
  build/DSH.app/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js
```

**验证**：日志出现 `ready after Ns`；`service.url` 非空；浏览器能打开该 URL（注意 token 不要外泄）。

---

## 5. 页面能打开但立刻断开 / 401

**症状**：浏览器显示 401、token 无效，或刷新后失效。

**原因**：`service.url` 是旧实例留下的；或手动复制 URL 时截断了 `token=`；或另一实例占用了端口。

**处理**：

```sh
rm -f ~/Library/Logs/DSH-Portable/service.url ~/Library/Logs/DSH-Portable/instance.lock
open build/DSH.app
```

从日志里取完整 URL（含 `token=` 全部字符）。不要把 URL 贴到公开 issue。

---

## 6. 提示“runtime missing” / “payload missing”（退出码 3）

**症状**：启动器弹窗，退出码 `3`。

**原因**：`Contents/Resources/runtime/` 不完整，通常是 `--skeleton` 构建，或复制被打断。

**处理**：

```sh
ls build/DSH.app/Contents/Resources/runtime/node/bin/node
ls build/DSH.app/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js
# 缺失就重跑（不要手抠文件）
./scripts/build-launcher.sh --force
```

**验证**：两个路径都存在且 `node -p process.version` 输出 `v22.18.0`。

---

## 7. 打开浏览器失败（退出码 5）

**症状**：日志 `no browser could be opened`，退出码 `5`。

**原因**：系统里没有受支持的浏览器，或 LaunchServices 未注册。

**处理**：

```sh
DSH_PORTABLE_BROWSER="Google Chrome" open build/DSH.app
# 或手动打开日志里的 URL
sed -n '1p' ~/Library/Logs/DSH-Portable/service.url
```

**验证**：浏览器打开且服务保持运行（关闭浏览器不会停止服务）。

---

## 8. 打包失败（zip / dmg）

| 退出码 | 含义 | 处理 |
| --- | --- | --- |
| `3` | bundle 不完整 | 先 `./scripts/build-launcher.sh --force` |
| `4` | 缺 `zip` 或 `hdiutil` | `xcode-select --install`；`hdiutil` 为系统自带 |
| `5` | zip 内可执行位丢失 | 不要用第三方压缩工具二次打包；重跑脚本 |
| `6` | bundle 含符号链接 | 去掉 `--link` 重建（`--link` 产物不可分发） |

dmg 挂载后若提示“应用程序副本已损坏”，按第 2 节去 quarantine / 重签。

---

## 9. 磁盘与清理

```sh
du -sh build dist ~/Library/Logs/DSH-Portable
rm -rf build dist                        # 可随时重建
rm -rf ~/Library/Logs/DSH-Portable       # 会清掉日志与 token
```

构建期至少需要 ~3 GB；`.app` 约 735 MB，zip 约 237 MB。

---

## 10. 仍然不行时该提供什么信息

提 issue 前请附（**先删 token**）：

1. `sw_vers`、`uname -m`、`xcode-select -p`；
2. `./verify.sh` 的输出；
3. `portable.log` 最后 50 行（用 `sed -E 's/token=[^ ]*/token=***/g'` 打码）；
4. 使用的 `DSH_VERSION` 与是否 `--ignore-scripts`；
5. 复现步骤与退出码。

上游问题（DSH 自身行为）请走官方渠道；本项目只负责构建与启动器。
