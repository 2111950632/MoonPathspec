# MoonPathspec

MoonBit 原生 Git pathspec 文件集合选择引擎。面向构建、打包、变更影响分析和 CI 工具，提供规则编译、文件选择及逐文件原因解释。维护者：石子硕（GitHub：2111950632）。[更新记录](CHANGELOG.md) · [项目申报书](项目申报书.md)。

兼容终点是 **Git 2.43.0 与 2.56.0 的完整公共 pathspec 语法和路径匹配语义**，输入模型为调用者提供的 UTF-8 仓库相对候选文件、当前目录 prefix 和四态属性。0.1.x 的 GPP-1 是历史范围，本轮不再以自行缩小的语法子集作为完成终点。目标、版本差别和责任边界见[兼容说明](docs/COMPATIBILITY.md)。

**0.2.0 本地整套验证已通过。** JS/Wasm GC 各 74 项核心测试、Node 40 项、13 个组合案例；Windows Git 2.56.0 常规差分 444 项、扩展差分 352 项通过，7 项仅原生 POSIX 场景明确未运行。独立解压包公开 API 两后端各 7 项通过，分发包在源码树外运行通过，见[本地记录](evidence/validation-0.2.0.json)。Linux 双版本对照、线上平台矩阵和 0.2.0 网络发布仍待完成，不由本地数据推定。0.1.x 证据保留为历史。

解析、匹配、属性条件、路径模式处理、预算和 JSON 诊断均由 MoonBit 实现。Node.js 负责命令行、UTF-8 文件输入输出和运行编译产物；运行时不启动 Git。候选发现、Git index、工作树枚举和 `.gitattributes` 的解析由接入方负责。

## 相对已有生态的增量

已有 bit、`mizchi/bit_ignore` 和多个 glob 包，本项目承认其通配、prefix、排除及解释等既有能力。交付重点是独立 MoonBit API 中的完整公共 pathspec 匹配目标、结构化 magic、四态属性、显式全局模式、精确语义回归及可审计失败。重叠和固定源码基线见[生态对照](docs/ECOSYSTEM.md)，不宣称各项能力独有。

例如 `doc/*.jpg` 的默认星号可选择 `doc/a.jpg` 与 `doc/sub/b.jpg`；`:(glob)doc/*.jpg` 仅选择前者。`:(glob)docs/*\[draft\].txt` 在一条规则内同时使用通配星号和字面方括号；`:(literal)` 则让整条主体按字面匹配，不能替代部分转义。

## 安装与运行

源码运行需 [MoonBit](https://www.moonbitlang.com/download)（moonc >= 0.10.22）及 Node.js >= 20。独立对照验证另需 Python >= 3.9 与 Git，无第三方 Python/npm 运行依赖。

```sh
git clone https://github.com/2111950632/MoonPathspec.git
cd MoonPathspec
moon build --target js --release --deny-warn
node cli.mjs --input examples/files.json --json
node cli.mjs explain --input examples/files.json
node cli.mjs --input examples/attributes.json --json
node cli.mjs --input examples/literal.json --json
```

三个最小输入分别选择 `main.mbt` 与 `src/parser.mbt`、`src/hand.mbt`、`src/a[1].mbt`。数据为自编候选清单，无需真实 Git 仓库。

```sh
node examples/escaped-pathspec/run.mjs
node cli.mjs --input examples/escaped-pathspec/02-glob-plus-escaped-brackets.json --json
node examples/ci-package/run.mjs
```

[13 个转义组合案例](examples/escaped-pathspec/README.md)涵盖字面 `[ ] ? *` 与通配混用、literal/glob/exclude、prefix/top/attr、未闭合字符类、原文精确匹配及 Windows 预处理。每例列出完整输入、独立预期、选择结果与解释；研究预期、实现运行通过和独立 Git 对照状态分开记录。

[CI 发布清单案例](examples/ci-package/README.md)模拟按发布/生成/渠道属性选择文件、排除测试与私有目录并附加许可证。两个案例集都是自编工作流，不宣称已被外部构建系统采用。

## 命令行、路径模式与全局设置

```sh
node cli.mjs --glob-pathspecs --path doc/a.jpg --path doc/sub/b.jpg -- 'doc/*.jpg'
node cli.mjs inspect --icase-pathspecs -- ':(prefix:4)src/A.txt'
node cli.mjs --path-mode posix --input examples/escaped-pathspec/01-escaped-brackets.json
node cli.mjs --help
```

默认使用 **POSIX 路径语义**，宿主运行在 Windows 不会自动切换。显式 `--path-mode windows` 或 JSON `options.windows=true` 启用 Windows Git 的非 top 路径预处理；实际匹配规则与 magic 仍由核心处理。候选路径统一用 `/`。

全局选项为 `--literal-pathspecs`、`--glob-pathspecs`、`--noglob-pathspecs`、`--icase-pathspecs`，对应 `--no-…-pathspecs` 可关闭同一设置。literal 全局模式同时关闭 magic 解析；noglob 仍允许某条 `:(glob)` 覆盖，glob 允许某条 `:(literal)` 覆盖。

Node 将四个 `GIT_*_PATHSPECS` 环境变量的原始字符串交给 MoonBit 解释。优先级为显式 CLI 字段、JSON `options` 字段、环境变量；未知字段、非法类型/布尔值和冲突返回错误。库 API 本身不读取进程环境。详见[全局设置规范](docs/COMPATIBILITY.md#global-settings-and-environment)。

PowerShell/Bash 应以单引号保护含特殊字符的规则，避免 shell 提前展开。API 中一个反斜线在 JSON 文本中写作 `\\`，shell 外层引号不是规则的一部分。cmd.exe 引号规则不同，可直接使用 JSON 输入文件。

`--` 后全部视为规则；`--paths FILE` 默认按行读取，`--null-input` 改为 NUL 分隔，`--null` 输出 NUL 分隔结果；`--input -` 读取标准输入。严格 UTF-8 解码，非法字节不替换后继续匹配。退出码 `0` 为成功（包括空集），`2` 为调用、配置、输入或资源错误；失败不返回部分选择结果。

## MoonBit API

已发布版本可用 `moon add 2111950632/moonpathspec` 安装；索引未更新时先运行 `moon update`。当前已确认的网络发布记录为 0.1.1；本轮新增语义在新版发布前请使用源码，不能据旧版本记录宣称新接口已发布。

在消费项目 `moon.pkg` 导入 `"2111950632/moonpathspec"`：

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

`compile(..., options={ ..default_pathspec_options(), glob: true })` 接受显式全局选项；`parse_pattern` 检查 magic，`ParsedPattern.prefix_length` 保留 `prefix:N` 字节长度。四态属性为 `Set`、`Unset`、`Unspecified`、`Value(String)`，由 `select(..., attribute=fn(path, name) { ... })` 查询。

Plan 不透明，编译后修改原规则数组不改变计划；每次选择在查询属性前保存候选快照。属性回调由调用者控制，应保持稳定并有界。公开接口见 [pkg.generated.mbti](pkg.generated.mbti)，JSON 桥接由 `dispatch` 提供。

## 匹配与 API 边界

兼容工作覆盖完整公共 magic、默认/glob/literal、反斜线转义、字符类、递归星号、prefix/top、排除与属性、全局选项及其组合。非法 magic 与失败的通配尝试不同：未闭合 `[`、尾随反斜线或倒序范围不得一律改成配置错误；原字符串同名候选还可走 Git 的精确匹配路径。

API 使用 UTF-8 字符串及规范仓库相对文件路径，保留输入顺序并拒绝重复候选。`?` 按一个 UTF-8 字节匹配，`icase` 按 Git 的 ASCII/C-locale 字节行为处理。非 UTF-8 文件名需要另行设计字节 API；这一输入表示边界不用于排除合法 pathspec 转义或其他合法语法。

接入方负责物理路径到仓库路径的转换、文件发现、索引/树对象来源、符号链接、工作树属性与 Git 子命令专属参数。完整 pathspec 匹配目标不表示实现整个 Git CLI 或文件系统。

## 资源限制与验证

默认规则数 256、每规则 4096 字节、每路径 16384 字节、候选 100000；单次通配 2000000 工作单位、总选择 20000000。硬上限分别为规则 4096、规则/路径 65536 字节、候选 1000000、单次 100000000、总选择 200000000；规则总字节另限 1 MiB，编译状态限 65536。JSON 输入限 16 MiB、深度 64，批量限 256 项及总工作 200000000。资源错误独立于“不匹配”，不会作为成功负结果返回。

工作单位不是耗时或 CPU 指令；调用者回调耗时不受库计量。匹配使用有预算的迭代 DP，候选与输入有独立限制。

```sh
npm run verify
```

完整验证包括检查、构建、JS/Wasm GC 核心测试、格式与接口核对、Node 命令行/案例/分发测试、独立 Git 对照、真实打包解压消费和源码树外分发运行。`MOONPATHSPEC_MOON`、`MOONPATHSPEC_PYTHON`、`MOONPATHSPEC_GIT` 可指定工具。每个对照结果必须记录实际 Git 版本与路径模式，Linux 的精确非 top 转义对照须由原生 Linux Git 执行。

打包解压消费不等于 Mooncakes 网络下载；两者分别记录。验证启动即失效旧成功状态，失败停止。源码计数将生产与测试分开，不作为组委会认证代码量。当前数量与状态见[本版验证记录](evidence/validation-0.2.0.json)，旧版数据不累加为本轮完成数量。

## 结构与开源

`parser.mbt` 解析 magic/全局选项，`glob.mbt` 实现字节匹配，`selector.mbt` 编译并选择，`protocol.mbt` 验证 JSON、转换环境布尔值并输出；`model.mbt` 定义模型。`*_wbtest.mbt`、`tests/` 和 `examples/` 提供回归、独立对照及运行案例。

十一月项目新写路径匹配与文件选择核心，十月 CatalogGuard 的翻译目录检查不作为本项目新增成果。使用 AI 辅助开发，维护者负责解释、验证及维护。项目采用 Apache-2.0，来源与保留声明见 [THIRD_PARTY.md](THIRD_PARTY.md)、[NOTICE](NOTICE)。审核结论和截止日期以主办方通知为准。
