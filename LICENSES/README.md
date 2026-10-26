# LICENSES

本目录保存随构建产物（zip / dmg）再分发的许可证**全文**。它们放在压缩包根目录、
与 `DSH.app` 同级，不进入 `.app` 内部；`scripts/make-dmg-or-zip.sh` 会在打包后
重新打开 zip 校验这些文件存在且非空。

| 文件 | 许可证 | 覆盖的组件 | 来源 | SHA-256 |
| --- | --- | --- | --- | --- |
| `Apache-2.0.txt` | Apache License 2.0 | `sherpa-onnx-darwin-x64` 及依赖树中 53 个 Apache-2.0 包 | <https://www.apache.org/licenses/LICENSE-2.0.txt> | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `LGPL-3.0.txt` | GNU Lesser General Public License v3.0 | `@img/sharp-libvips-darwin-x64@1.3.4`（libvips） | <https://www.gnu.org/licenses/lgpl-3.0.txt> | `e3a994d82e644b03a792a930f574002658412f62407f5fee083f2555c5f23118` |

两份文本均为官方原文，未经修改（11358 B / 7652 B）。组件清单、修改声明（sherpa
`minos 15.0 → 11.0`、前端 polyfill）与 LGPL 源码要约见
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。

复核：

```sh
sha256sum -c <<'EOF'
cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  LICENSES/Apache-2.0.txt
e3a994d82e644b03a792a930f574002658412f62407f5fee083f2555c5f23118  LICENSES/LGPL-3.0.txt
EOF
```
