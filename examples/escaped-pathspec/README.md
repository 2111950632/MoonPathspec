# 字面特殊字符与通配混用：可运行验收案例

目标是直接展示“同一条规则既有通配，又有字面 [ ] ? *”的行为，并展示与 literal、glob、exclude、prefix、top 和属性条件的组合。13 个请求共用手工候选清单，预期保存在 expected.json；预期不是由生产匹配器生成。

Node 入口仅读取 JSON、调用编译后的 MoonBit 核心、核对固定预期、输出解释，不解析或改写规则，也不计算属性条件。候选及属性由调用方提供，不扫描磁盘、不调用运行时 Git、不解析 .gitattributes。

## 运行

在仓库根目录：

~~~sh
moon build --target js --release --deny-warn
node examples/escaped-pathspec/run.mjs
node cli.mjs --input examples/escaped-pathspec/02-glob-plus-escaped-brackets.json --json
node cli.mjs explain --input examples/escaped-pathspec/06-literal-glob-exclude.json
~~~

脚本对每个请求检查退出码和完整选择列表，并打印关键候选的 included_by、excluded_by、reason。下标从 0 开始。任何不一致都会以非零退出，不会把尚未通过的目标行为描述成通过。

## API 字符串与 shell 引号必须分开

以下三种写法表示同一条 API 规则，其中传入核心的每个转义处都只有**一个反斜线**：

| 层次 | 写法 |
|---|---|
| API 实际字符串 | `:(top,glob)docs/*\[draft\].txt` |
| JSON 文本 | `":(top,glob)docs/*\\[draft\\].txt"` |
| PowerShell 或 Bash 的单引号参数 | `':(top,glob)docs/*\[draft\].txt'` |

shell 的外层单引号防止 shell 提前展开星号，不会成为 API 字符串的一部分。JSON 中两个反斜线是 JSON 编码，不是要求核心消费两个反斜线。Windows 命令提示符 cmd.exe 的单引号规则不同，建议使用本目录 JSON 请求文件。

直接命令示例，PowerShell / Bash 均使用单引号：

~~~sh
node cli.mjs --path 'docs/a[draft].txt' --path 'docs/adraft.txt' -- ':(top,glob)docs/*\[draft\].txt'
~~~

预期只输出 docs/a[draft].txt。星号是通配符；反斜线后面的方括号是字面字符。

literal magic 是整条规则按字面匹配，不是在同一条规则内启用部分通配；literal 和 glob 不能写在同一条 magic 中。第 06 例使用不同规则组合两种模式，并把排除统一放到最后处理。

## 场景、输入与预期

每项 JSON 都可独立交给 cli.mjs --input 运行。下表显示关键规则的 API 原文，完整候选和属性保存在对应文件；输出顺序保留候选输入顺序。

| 编号 | 关键规则 / 组合 | 预期 |
|---|---|---|
| 01 | `:(top)docs/\[draft\].txt` | 只选 docs/[draft].txt，不选 docs/draft.txt |
| 02 | `:(top,glob)docs/*\[draft\].txt` | 选择 docs/ 下 5 个以字面 [draft].txt 结尾的直接文件；不跨入 nested/ |
| 03 | `:(top)docs/*\[draft\].txt` | 默认星号可跨 /，在第 02 例之外再选择 nested/a[draft].txt，共 6 个 |
| 04 | `两条规则 a\?report.txt 与 a\*report.txt` | 只选文件名中真正带 ? 或 * 的两个文件，不选 abreport.txt |
| 05 | `两条 glob 规则 *\?report.txt 与 *\*report.txt` | 星号之后的转义仍为字面；同样只选前述两个文件 |
| 06 | `literal logo[dark].svg + glob *\[draft\].txt + literal exclude skip[draft].txt` | 方括号图标与文档并集，最终排除 skip，共 5 个；不选 logod.svg |
| 07 | prefix=src，top+glob+attr:publish -generated，附加根 LICENSE 并排除 skip | 选择 [draft].txt、a[draft].txt、keep[draft].txt、LICENSE；b[draft].txt 被 generated=true 阻止 |
| 08 | `prefix=src，相对 ../docs/*\[draft\].txt + 属性，根 LICENSE 与排除使用 top` | POSIX 规则预期与第 07 例相同；精确非 top 参数仍需 Linux Git 对照 |
| 09 | 未闭合 docs/a[broken 与不存在的 docs/no[ | 有同名候选时保留精确路径回退，选 a[broken；不存在时合法空匹配 |
| 10 | :(top,glob)docs/f[o][o].txt | 同时选择原字符串同名 f[o][o].txt 与通配命中的 foo.txt，保留 Git 的“路径匹配自身”行为 |
| 11 | :(top)docs/file[z-a].txt | 实测选原字符串同名 file[z-a].txt 和 filez.txt；不擅自把倒序范围改成语法错误 |
| 12 | docs/no 后一个尾随反斜线，以及 docs/* 后一个尾随反斜线 | 两项都没有命中，成功空集；不是语法错误或资源错误 |
| 13 | `非 top docs/\[draft\].txt，显式 options.windows=true` | Windows Git 路径预处理会把反斜线视为分隔符，本候选集为空；与默认 POSIX 语义分开 |

第 06 例中 skip[draft].txt 的解释应同时记录 included_by=[1]、excluded_by=[2]，最终不被选中。第 07 例中 b[draft].txt 属性不满足，不能当作已经包含后再排除；LICENSE 则由独立 top,literal 规则选中。这些差别可由解释输出直接核对。

## Git 独立核验范围

参考固定版本 Git v2.51.0：

- [t6130：glob 与 literal，以及原字符串同名路径](https://github.com/git/git/blob/v2.51.0/t/t6130-pathspec-noglob.sh)
- [t6137：字面星号、问号与方括号](https://github.com/git/git/blob/v2.51.0/t/t6137-pathspec-wildcards-literal.sh)
- [Git pathspec 术语与 magic 定义](https://github.com/git/git/blob/v2.51.0/Documentation/glossary-content.adoc#def_pathspec)

本目录固定预期独立研究于 2026-11-25，执行基线是 Git 2.56.0.windows.4。通过临时 Git index 存放候选，使用 git ls-files --full-name -z 查询结果，再恢复到调用者候选顺序。包含 * 和 ? 的文件名只存入 index，不要求 NTFS 工作树创建非法名称；这类 index-only 输入不冒充 Windows 文件系统能力。属性来自实际 git check-attr -z 读取。

第 01–07、09–12 例采用 top magic，在 Windows Git 中保留规则主体原文，已经独立查询 Git 匹配结果；这不等于已经运行了原生 POSIX Git。第 13 例独立查询 Windows Git 非 top 参数。第 08 例目前仅有归一化等价的 top 参照，精确的非 top POSIX 参数待 Linux Git 验证。各例状态记在 expected.json，后续以 CI 实际结果补充，不把研究预期当成实现通过。

## 平台与错误边界

默认输入解释为 POSIX 风格 Git pathspec 原文；宿主运行在 Windows 不会自动切换。需要复现 Windows Git 的非 top 路径预处理时，调用方显式传 options.windows=true。该选项属于解析模式，Node 入口不自行替换反斜线。候选路径仍统一使用 /；反斜线不是候选路径自动转换指令。

四态属性由调用者提供，规则只查询状态；本目录不实现 .gitattributes 的继承或宏。只覆盖 UTF-8、仓库相对候选路径上的选择语义，不宣称覆盖所有 Git 子命令的参数、仓库枚举、任意编码文件名或主机文件系统行为。资源上限或非法 magic 仍应返回结构化错误；成功空集、精确路径回退与调用错误不能混淆。
