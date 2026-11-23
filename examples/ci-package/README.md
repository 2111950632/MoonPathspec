# CI 发布文件选择案例

一个多包仓库需要发布 `packages/widget`：只收入标记为可发布、非生成、稳定渠道的文件；移除测试与私有目录；附带根目录许可证。发布任务位于 `tools/release`，规则仍需明确指向仓库根。若文件名包含方括号，还需要按字面名称选择，避免被当作字符类。

本案例展示如何把**调用者已取得的候选清单与属性表**交给 MoonPathspec，得到发布清单和逐文件原因。输入是自行编写的可复现工作流数据，不是外部用户采纳记录。示例不遍历文件系统、不查询 Git index、不解析 `.gitattributes`、不创建压缩包，也不执行真实发布。

Node 脚本只读 JSON、调用已编译的 MoonBit 核心、核对固定预期并输出；规则解析、匹配、属性条件和选择解释均由 MoonBit 完成。在真实工具中，候选收集和属性解析由调用方提供，选中的路径再交给打包器。

## 运行

在仓库根目录运行，需 MoonBit 和 Node.js：

```sh
moon build --target js --release --deny-warn
node examples/ci-package/run.mjs
node --test tests/scenarios.mjs
```

脚本依次核对三个场景，末尾输出 `Verified 3 scenarios against handwritten expected results.`。`expected.json` 是人工根据下述发布政策写下的预期，不由生产匹配器生成。

## 1. 生成稳定发布清单

```sh
node cli.mjs --input examples/ci-package/release.json
node cli.mjs explain --input examples/ci-package/release.json
```

预期选择，顺序与候选输入一致：

```text
LICENSE
packages/widget/src/api.mbt
packages/widget/docs/guide.md
packages/widget/assets/logo.svg
```

四条规则按 JSON 顺序编号，解释中的规则下标从 **0** 开始：

| 规则 | 政策 |
|---|---|
| `:(top,glob,attr:publish -generated channel=stable)packages/widget/**` | 从根选择本包可发布、明确非生成、稳定渠道的内容 |
| `:(top,exclude,glob)**/*_test.mbt` | 最后排除任意深度的测试文件 |
| `:(top,exclude)packages/widget/private` | 最后排除整个私有目录及后代 |
| `:(top,literal)LICENSE` | 无视调用位置，附加根目录许可证 |

`api_test.mbt` 虽满足第 0 项，最终被第 1 项排除；`private/debug.mbt` 被第 2 项排除。`generated/version.mbt` 的 `generated=true`、`docs/draft.md` 的 `channel=beta` 不满足正项。另一个包的源码也不会进入清单。`prefix` 为 `tools/release`，四条 `top` 规则仍以仓库根为起点。

典型解释：

```text
+ "LICENSE": included_by_pattern; include=3 exclude=
- "packages/widget/src/api_test.mbt": excluded_by_pattern; include=0 exclude=1
- "packages/widget/private/debug.mbt": excluded_by_pattern; include=0 exclude=2
- "packages/widget/generated/version.mbt": no_positive_match; include= exclude=
```

## 2. 属性四态不是布尔开关

```sh
node cli.mjs --input examples/ci-package/attribute-states.json
node cli.mjs explain --input examples/ci-package/attribute-states.json
```

预期为 `assets/set.txt`、`notes/unset.txt`、`licenses/missing.txt`、`metadata/stable.json`。

| 规则条件 | JSON 属性值 | 结果与合法边界 |
|---|---|---|
| `attr:release` | `true`，即 Set | 选中 `assets/set.txt`；字符串 `"stable"` 不算 Set |
| `attr:-release` | `false`，即 Unset | 选中 `notes/unset.txt`；缺失属性不算 Unset |
| `attr:!release` | 缺失，即 Unspecified | 选中 `licenses/missing.txt`；`false` 不算 Unspecified |
| `attr:release=stable` | `"stable"`，即 Value | 选中 `metadata/stable.json`；`true` 不等于字符串值 |

这可以表达“明确标为非生成”与“没有生成属性”两种不同发布政策。应用若需要后者，应明确使用 `!generated`；本例第一场景刻意要求 `-generated`。条件之间按 AND 组合，包含规则之间取并集，排除规则在最后生效。

## 3. 子目录调用与方括号文件名

```sh
node cli.mjs --input examples/ci-package/literal-prefix.json
node cli.mjs explain --input examples/ci-package/literal-prefix.json
```

调用者的 `prefix=packages/widget`。预期只选择根目录 `LICENSE` 和 `packages/widget/assets/logo[dark].svg`。

- `:(literal)assets/logo[dark].svg` 按 prefix 定位；`[dark]` 保持字面字符，不会选择 `logod.svg`。
- `:(top,literal)LICENSE` 从根定位，不会选择 `tools/LICENSE`。
- 另一个包下的同名文件不在调用者 prefix 中，不会被相对规则选中。

## 使用边界与失败处理

候选必须是规范化、仓库相对 UTF-8 文件路径，统一使用 `/`。属性表是调用者提供的确定输入，示例不模拟 Git 的属性继承、宏或优先级。完整支持范围见 [GPP-1 合同](../../docs/COMPATIBILITY.md)。

生产调用方应先检查响应的 `exit_code`：`0` 表示成功，含合法空结果；`2` 表示输入、语法或资源错误。错误时 `selected=[]`，不能把错误当作成功的空发布包。需要机器可读结果时加 `--json`，或使用公开 MoonBit API 的 `Result`。本例核对失败会退出 1，不会继续报告成功。
