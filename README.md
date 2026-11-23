# MoonPathspec

MoonBit 原生 Git Pathspec 文件集合选择引擎。为构建工具、打包工具、变更影响分析和 CI 提供可嵌入的规则编译、路径选择及原因解释。维护者：石子硕（GitHub：2111950632）。当前代码版本：0.1.1。[更新记录](CHANGELOG.md)。

0.1.0 已公开上传 GitHub，并通过 [Linux 与 Windows 线上完整验证](https://github.com/2111950632/MoonPathspec/actions/runs/45119787573)：构建、两种后端测试、Git 对照、真实打包消费及独立分发运行均成功。[本地验证记录](evidence/validation-0.1.0.json)与[线上核验记录](evidence/github-validation-0.1.0.json)分别保留。[Mooncakes 0.1.0](https://mooncakes.io/docs/2111950632/moonpathspec) 已发布；独立项目实际下载后，JavaScript 与 Wasm GC 各 4 项公开接口测试通过，7 个生产 MoonBit 源文件及 4 个清单/接口文件与本地逐字节一致，见 [发布与下载验证](evidence/mooncakes-validation-0.1.0.json)。

核心由 MoonBit 实现，调用者提供仓库相对文件路径和属性查询函数。Node.js 只负责命令行、文件输入输出和运行编译产物。运行时不调用 Git，不读取 Git index，不遍历仓库，不自行解析 `.gitattributes`。Git 只作为独立测试参考。

## 相对已有生态的增量

已有 `mizchi/bit_ignore`、glob 包及 bit 内部的部分 Pathspec 实现。本项目聚焦独立可复用的 magic 解析、默认通配与 glob 模式差别、top/prefix、组合排除、四态属性条件及解释接口。查重基线和固定源码链接见 [生态对照](docs/ECOSYSTEM.md)，不宣称生态绝对空白。

例如候选路径为 `doc/a.jpg` 和 `doc/sub/b.jpg` 时：

| 规则 | 选择结果 |
|---|---|
| `doc/*.jpg` | 两个路径 |
| `:(glob)doc/*.jpg` | 仅 `doc/a.jpg` |

## 安装与运行

源码运行需 [MoonBit](https://www.moonbitlang.com/download)（moonc >= 0.10.22）及 Node.js >= 20。完整独立验证还需 Python >= 3.9 和 Git；没有第三方 Python/npm 运行依赖。

```sh
git clone https://github.com/2111950632/MoonPathspec.git
cd MoonPathspec
moon build --target js --release --deny-warn
node cli.mjs --input examples/files.json --json
node cli.mjs explain --input examples/files.json
node cli.mjs --input examples/attributes.json --json
node cli.mjs --input examples/literal.json --json
```

三个输入分别选择 `main.mbt` 与 `src/parser.mbt`、`src/hand.mbt`、`src/a[1].mbt`。`explain` 显示每个文件被哪项规则包含或排除。示例是自行编写的文件清单，无需真实 Git 仓库或设备。

```sh
node cli.mjs --path doc/a.jpg --path doc/sub/b.jpg -- ':(glob)doc/*.jpg'
node cli.mjs inspect -- ':(top,icase,glob)**/*.md'
node cli.mjs --help
```

PowerShell/macOS/Linux 都应给含特殊字符的规则加引号。`--` 之后全部作为规则。`--paths FILE` 支持每行一个路径，`--null-input` 改为 NUL 分隔；`--null` 使用 NUL 分隔输出。`--input -` 读取标准输入 JSON。输入文件以严格 UTF-8 解码，非法字节不会被替换后继续匹配。

退出码：`0` 完成选择（包括空结果），`2` 参数、文件、配置、语法、范围或资源错误。错误 JSON 的 `selected` 为空，不返回部分选择结果。路径列表顺序保留，重复候选报错。

## 应用案例：CI 发布文件选择

[完整案例](examples/ci-package/README.md) 展示多包仓库从子目录发起发布：按
`publish`、`generated`、`channel` 属性筛选，统一排除测试与私有目录，并附加根目录
许可证。包含三组可运行输入、人工预期结果和逐文件解释，也演示四态属性及字面方括号。

```sh
node examples/ci-package/run.mjs
node cli.mjs explain --input examples/ci-package/release.json
```

第一组选择 `LICENSE`、`packages/widget/src/api.mbt`、
`packages/widget/docs/guide.md` 和 `packages/widget/assets/logo.svg`。
案例使用调用者提供的合成清单；路径发现、属性来源和后续打包由接入方负责。

## MoonBit API

从 Mooncakes 安装：`moon add 2111950632/moonpathspec`。在消费项目的 `moon.pkg` 中导入 `"2111950632/moonpathspec"`，即可通过 `@moonpathspec` 调用下述公开 API。

```moonbit
let plan = @moonpathspec.compile([
  ":(glob)**/*.mbt",
  ":(exclude)vendor",
]).unwrap()
let result = @moonpathspec.select(plan, [
  "main.mbt", "src/a.mbt", "vendor/a.mbt",
]).unwrap()
// result.selected == ["main.mbt", "src/a.mbt"]
let reason = @moonpathspec.explain(plan, "vendor/a.mbt").unwrap()
// reason.selected == false; reason.excluded_by == [1]
```

属性值分 `Set`、`Unset`、`Unspecified`、`Value(String)`。`select(..., attribute=fn(path, name) { ... })` 接受调用者的纯查询函数；不提供时全部为 Unspecified。回调内部耗时不能由库计量，调用者应保持其有界。

公开接口见 [pkg.generated.mbti](pkg.generated.mbti)。`parse_pattern` 可单独检查 magic；`compile` 返回不透明 Plan，调用者修改原输入数组不会改变它。`dispatch` 是版本 1 JSON 桥接入口。

## GPP-1 支持边界

- UTF-8、规范化的仓库相对候选文件路径；分隔符为 `/`，拒绝 NUL、空路径、Windows 盘符或反斜线开头的路径（含盘符相对形式）、绝对路径及 `.`/`..` 候选组件。普通规则按 prefix 归一化；`top` 规则保留主体原文，按仓库根比较。
- long/short magic：top、literal、glob、icase、exclude、四态 attr 条件。未知 magic 和 literal/glob 冲突明确报错。裸 `:` 作为 prefix 文件集的正项；包含规则取并集，排除在最后生效。
- 字节通配、ASCII icase、字符类及列明的 POSIX 类。`?` 匹配一个 UTF-8 字节，不是一个可见字符；调用者 prefix 不被 icase 折叠。
- 跨平台首版拒绝非 literal 主体中的反斜线，返回 `unsupported_backslash`；需要字面括号等字符时用 `:(literal)`。属性 magic 值的转义不受此主体限制。literal 中反斜线按字面字节处理，不当作 Windows 分隔符。
- 不支持 Git 内部 magic、任意非 UTF-8 文件名、所有 Git 子命令特殊处理、环境变量改变的全局 pathspec 模式及完整 Git 文件系统行为。

完整规范、已知平台差别和错误边界见 [兼容合同](docs/COMPATIBILITY.md)。这是显式范围内的兼容库，不是 Git 的完整替代品。

## 资源限制

默认最多 256 条规则、每规则 4096 字节、每路径 16384 字节、100000 个候选；每次通配匹配 2000000 工作单位，整次选择 20000000。工作单位包括匹配 DP 单元格、路径/字面比较及属性条件预留，不等同于 CPU 指令或耗时。失败条件查询也计费；不足时明确失败。

配置必须为正整数且不超过硬上限：规则 4096、每规则/路径 65536 字节、候选 1000000、单匹配 100000000、总选择 200000000；规则总字节另限 1 MiB。编译总状态限 65536，普通 token 计 1、字符类及其两张 256-bit 掩码计 17；分配前检查，超限返回 `compile_limit`。JSON 输入限 16 MiB、深度 64；测试批量入口限 256 项、总工作 200000000，任一匹配耗尽预算就停止批量而不返回部分结果。匹配采用迭代 DP，避免指数递归回溯。

## 验证

0.1.1 [完整本地验证](evidence/validation-0.1.1.json)：JS 与 Wasm GC 各 65 项核心测试、34 项 Node 集成/边界/场景/分发测试、424 项 Git 等价对照及另计的 20 项范围拒绝全部通过。实际包解压后的独立消费在两种后端各通过 5 项公开 API 测试。网络发布与线上 CI 以各自记录为准。

```sh
moon check --target all --deny-warn
moon test --target js --deny-warn
moon test --target wasm-gc --deny-warn
moon fmt --check
moon info
moon build --target js --release --deny-warn
npm test
python tests/git_oracle.py
```

`npm run verify` 顺序完成上述检查，以及真实 `moon package` 解包后的独立公共 API 消费和 JS 分发包生成。生成的 `dist/` 可以单独复制并以 Node 运行，验证还会把它复制到源码树外实际执行。可用 `MOONPATHSPEC_MOON`、`MOONPATHSPEC_PYTHON`、`MOONPATHSPEC_GIT` 指定工具路径。缺少工具、Git 不一致、预算错误或构建失败都会停止，不会跳过后宣称通过。

Git 对照脚本创建临时仓库，逐次调用 `git ls-files --full-name -z`；固定案例和固定种子生成案例均由独立 Git 得到预期，不调用生产 matcher 造答案。支持范围内等价案例与明确范围拒绝案例分开计数，报告保留 Git 实际结果、版本、输入摘要和失败详情。CI 已在 Linux 与 Windows 两个平台完成首次完整验证。

`scripts/check-consumer.py` 从真实发布 ZIP 提取源码并建立单独消费项目；这是打包使用验证，不能冒充 Mooncakes 网络下载验证。`node scripts/count-source.mjs` 将生产 MoonBit、测试分开统计，结果不是组委会认证的有效代码行。

注册表消费复验可在仓库外建立独立目录，使用 [发布验证记录](evidence/mooncakes-validation-0.1.0.json) 中的模块及包清单，将 [消费用例](tests/registry_consumer.mbt.fixture) 保存为 `registry_consumer_test.mbt`，然后运行记录中的两种后端测试命令。不要加入本地路径覆盖或 workspace 替代依赖。

## 结构与开源

`parser.mbt` 解析 magic，`glob.mbt` 实现有预算字节匹配，`selector.mbt` 编译并选择文件集，`protocol.mbt` 验证 JSON 请求和输出；`model.mbt` 是公开模型。`*_wbtest.mbt` 为核心测试，`tests/` 包含宿主集成与独立 Git 对照，`examples/` 提供最小可运行输入。

本项目为十一月独立新项目。十月 CatalogGuard 已通过验收，其翻译目录检查代码不作为本项目新增成果。使用 AI 辅助开发，维护者负责解释、验证及维护。代码使用 Apache-2.0；标准库归属及参考说明见 [NOTICE](NOTICE)、[THIRD_PARTY.md](THIRD_PARTY.md)。

比赛方向和生态增量自查不等于主办方审核结论。十一月报名及验收截止以官方最新通知为准。
