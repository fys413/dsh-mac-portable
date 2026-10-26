# BRAND — 品牌与命名规则（落实上游 `BRAND_GUIDELINES.md`）

本文件把上游 DeepSeek Harness 仓库的 `BRAND_GUIDELINES.md` 落成**可检查的规则**。
凡与本仓库有关的仓库名、应用名、包名、图标、文案，都必须满足下面的清单。

## 0. 上游要求摘要（原文要点，非逐字翻译）

1. 在**描述性文本**里可以使用完整名称，例如 "built on DeepSeek Harness"。
2. 项目**命名**建议使用缩写 **"DSH"**。
3. **不要在项目名里直接使用完整商标 "DeepSeek Harness"**；它是 DeepSeek 的注册商标，
   直接用作项目名可能构成商标侵权，也可能被误认为官方项目。
4. 不要使用官方 logo/视觉素材暗示官方背书、赞助或隶属关系。

## 1. 本项目的固定命名

| 对象 | 取值 | 说明 |
| --- | --- | --- |
| 仓库名 | `dsh-mac-portable` | 只用缩写 DSH，不含完整商标 |
| 应用包名 | `DSH.app`（显示名 **DSH Portable**） | `CFBundleName` / `CFBundleDisplayName` 均为 `DSH Portable` |
| `CFBundleIdentifier` | `io.github.<user>.dsh-mac-portable`（默认，按 `$DSH_BUNDLE_USER`/`$USER` 生成；`--bundle-id` 可改） | **禁止** `ai.deepseek.*`、`com.deepseek.*` 或任何含 `deepseek` 的标识 |
| 可执行文件名 | `Contents/MacOS/DSH` | 与 `CFBundleExecutable` 一致 |
| 日志目录 | `~/Library/Logs/DSH-Portable/` | 不使用官方产品名 |
| 环境变量前缀 | `DSH_PORTABLE_*` | 例如 `DSH_PORTABLE_BROWSER` |
| 版权行 | `Unofficial build. Not affiliated with DeepSeek.` | 写进 `Info.plist` 的 `NSHumanReadableCopyright` |

## 2. 必须做的声明

1. **README 第一屏**必须有"非官方"声明，明确"与 DeepSeek 无隶属关系、未获其背书"。
2. **应用内**：启动失败/超时等对话框的标题使用 `DSH Portable`，文案中不得暗示官方。
3. **发布说明 / Release notes**：首段写 "Unofficial build of DSH for macOS Big Sur (Intel x64)."
4. **描述上游关系时**用描述性句子：`built on DeepSeek Harness`、`runs the official
   @deepseek-ai/dsh npm package`；不要写成 `DSH by DeepSeek`、`official DSH`。

## 3. 禁止事项

- ❌ 项目名/仓库名/组织名包含 `deepseek-harness`、`DeepSeek Harness`、`DeepSeek`。
- ❌ `CFBundleIdentifier` 使用 `ai.deepseek.*` 或任何 DeepSeek 域名反写。
- ❌ 使用官方图标、官方 favicon、官方截图作为应用图标或商店素材。
- ❌ 在任何地方声称 "official"、"官方版"、"官方构建"、"DeepSeek 认证"。
- ❌ 注册含 DeepSeek 商标的域名、社交账号、包管理器命名空间来分发本项目。
- ❌ 把上游 `LICENSE` 的版权人改成自己（上游版权归 DeepSeek，见 `NOTICE.md`）。

## 4. 图标

本仓库**不附带任何图标文件**（避免误用官方素材）。`build-launcher.sh` 不生成
`.icns`，产物使用系统默认图标。若要自带图标：

1. 自己绘制或用你有权使用的素材，用 `python3 scripts/make-icns.py -s <你的 PNG> -o DSH.icns`
   生成（需 Pillow；不依赖 macOS 的 `iconutil`）；
2. 放进 `DSH.app/Contents/Resources/DSH.icns`，并在 `Info.plist` 增加
   `<key>CFBundleIconFile</key><string>DSH</string>`；
3. 确认图标里不含 DeepSeek 商标元素。

## 5. 自检（发布前跑一遍）

```sh
# 1) 不得出现 DeepSeek 的反域名标识
grep -rn "ai\.deepseek\|com\.deepseek" --include='*.sh' --include='*.md' --include='*.plist' . || echo "OK: no deepseek bundle id"

# 2) README 必须带非官方声明
grep -q "非官方" README.md && echo "OK: unofficial notice present"

# 3) 仓库名不得含完整商标
basename "$PWD" | grep -qi "deepseek.harness" && echo "FAIL: repo name uses the full trademark" || echo "OK: repo name"
```

`verify.sh` 会自动执行第 1、2 项；第 3 项取决于你 clone 下来的目录名。

## 6. 上游链接

- 上游仓库：<https://github.com/deepseek-ai/deepseek-harness>
- 上游品牌指南：仓库根目录 `BRAND_GUIDELINES.md`
- 上游许可证：仓库根目录 `LICENSE`（MIT）
