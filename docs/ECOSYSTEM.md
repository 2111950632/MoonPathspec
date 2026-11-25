# Ecosystem comparison and incremental scope

Frozen ecosystem research: 2026-11-23. Compatibility target revised: 2026-11-25.
This comparison identifies observed overlap and the
specific scope chosen for MoonPathspec. It is not a claim that the MoonBit
ecosystem has no similar code. Search indexing, package summaries, and current
branches can change; an absent search result is not proof of absence.

## 中文摘要：可复用价值与增量边界

MoonPathspec 面向已经拥有文件清单的构建、打包和 CI 工具：调用者提供路径与属性，库负责编译、选择并解释结果。兼容终点是 Git 2.43.0 与 2.56.0 的完整公共 pathspec 语法和匹配语义，不再以 0.1.x 的自定义 GPP-1 子集作为完成终点。独立 MoonBit API 运行时无需启动 Git；文件发现和属性来源由调用者控制。

下表基于本文固定的 bit 源码和列明的包文档。对某个函数的观察不代表整个项目缺少相关能力，也不宣称普通 glob、排除或解释功能是本项目首创。

| 使用者需要解决的问题 | 已核实的生态基础 | MoonPathspec 的具体交付 |
| --- | --- | --- |
| 在工具中直接调用文件集合选择 | `bit_ignore` 和现有 glob 包已提供匹配、忽略规则等能力；bit 的命令内部已有 pathspec 处理。 | 独立的 `compile`、`select`、`explain` 接口和不透明 Plan，接收调用者的候选路径；无需嵌入完整 Git 命令实现。 |
| 保留 pathspec 的不同模式与作用域 | 固定 bit 基线已有 prefix、exclude、icase 和后代路径选择；被检查的 magic 函数未分别保留 top/literal/glob 条件。 | 以两个固定 Git 版本的完整公共语义为目标，交付结构化 magic、转义与原文精确回退、默认/glob 区别、top/prefix、全局设置及组合排除，并逐项对照。 |
| 按发布、生成等属性筛选 | 被检查的 bit magic 函数未保留四态属性条件；这不是对其全部代码或其他包的全面否定。 | 用回调区分 Set、Unset、Unspecified 与字符串 Value，组合 `attr:` 条件；核心不自行读取 `.gitattributes`。 |
| 对结果和失败给出可审计依据 | 现有包也有诊断、解释或编译匹配能力；单独增加解释文本不足以构成差异。 | 从同一次选择返回原始规则索引与原因，配套 UTF-8 字节定位、编译/匹配预算、独立 Git 对照，以及单独标识的输入与资源失败案例。 |

例如打包工具可将已有文件清单和发布标记交给 `:(attr:publish -generated)src/**`：现有 [属性案例](../examples/attributes.json) 只选择 `src/hand.mbt`，排除已生成文件及未满足发布条件的文件。仓库根目录运行 `node cli.mjs explain --input examples/attributes.json` 可查看逐文件原因。普通模式与 `glob`、prefix 与 literal 的最小案例分别见 [README](../README.md) 和 [literal 输入](../examples/literal.json)。这些案例展示已实现的选择核心，不宣称已接入某个外部构建系统。

接口边界保持明确：输入为 UTF-8 仓库相对路径，`icase` 按 Git 的 ASCII/C-locale 字节行为处理；候选发现、Git index、完整文件系统行为和属性文件解析由接入方负责。这个输入/外部责任边界不能用于排除合法反斜线转义或缩减公共语法。默认 POSIX 与显式 Windows 预处理分别验证，不声称对其他包有未经测量的性能优势。完整终点与验证状态见[兼容说明](COMPATIBILITY.md)。[0.1.1 发布验证](../evidence/mooncakes-validation-0.1.1.json)仅覆盖历史版本，不代表本轮新增行为已通过或发布。

[13 个字面特殊字符与通配混用案例](../examples/escaped-pathspec/README.md)提供可运行输入、独立预期和解释，包括同条规则内的星号与转义方括号、转义问号/星号、literal/glob/exclude 组合及 prefix/top/attr。案例为自编清单；研究预期、当前实现通过、Windows Git 对照和原生 Linux Git 对照分别记录，不宣称外部项目已采纳。

## Frozen source baseline: bit

The primary source comparison is
[`bit-vcs/bit` at `c014395fd512678e89b6945a19925ed817b99b83`](https://github.com/bit-vcs/bit/tree/c014395fd512678e89b6945a19925ed817b99b83).
The commit was observed as `main` HEAD through the GitHub source page and its
commit feed. Its
[`bit_ignore` manifest](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit_ignore/moon.mod)
declares `mizchi/bit_ignore` version 0.50.0. The corresponding
[Mooncakes package](https://mooncakes.io/docs/mizchi/bit_ignore%400.50.0) is an
existing reusable ignore/glob package, not an unfilled project idea.

| Inspected source | Observed capability | Consequence for MoonPathspec |
| --- | --- | --- |
| [`bit_ignore` public interface](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit_ignore/src/pkg.generated.mbti) and [implementation](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit_ignore/src/ignore.mbt) | `Matcher`, `parse`, `match_glob`, scoped ignore rules, negation, directory awareness, bracket expressions, POSIX classes, and escapes. | A new `.gitignore` parser or generic glob wrapper would duplicate substantial existing work. |
| [`ls_files.mbt`: `parse_pathspec_magic`, line 1086](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit/cmd/bit/ls_files.mbt#L1086) | An internal pathspec parser returning raw text plus exclude/icase booleans, including `:!` and long-form recognition of exclude/icase. | Existing MoonBit pathspec handling must be acknowledged. The incremental target is structured complete supported magic and validation, not the first occurrence of the word pathspec. |
| [`normalize_ls_files_filters`, line 658](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit/cmd/bit/ls_files.mbt#L658) | Current-directory prefix handling and normalization. | Prefix handling alone is already overlapping capability. |
| [`ls_files_matches_filters`, line 1245](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit/cmd/bit/ls_files.mbt#L1245) and [`ls_files_pathspec_matches`, line 1371](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit/cmd/bit/ls_files.mbt#L1371) | Positive/exclude composition, icase transformation, wildcard matching, and literal path/descendant checks within a Git command implementation. | Exclusion, icase, and selecting descendants are not sufficient novelty claims by themselves. |
| [`bit_lib` interface](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit_lib/src/pkg.generated.mbti) and [`last_modified.mbt`](https://github.com/bit-vcs/bit/blob/c014395fd512678e89b6945a19925ed817b99b83/modules/bit_lib/src/last_modified.mbt) | A separate public `last_modified_pathspec_matches` helper with limited prefix/trailing-star logic. | The new core should expose a reusable supported selection contract rather than treat command-local helpers as an ecosystem-wide absence. |

At this pinned baseline, the inspected `ls-files` magic parser does not retain
separate top/literal/glob/attribute conditions. It strips the long-form wrapper
and recognizes only the booleans in its return type. This is a source-level
observation about the inspected functions, not a claim that the whole bit
repository lacks every related feature or that future bit releases will keep
the same boundary.

## Other observed overlap

The Mooncakes registry also exposed these relevant existing packages during
research. The entries below describe registry/documentation scope; they are not
a claim of a complete source audit of every listed project.

| Existing package | Advertised or indexed scope |
| --- | --- |
| [`sennenki/ignore` 0.1.1](https://mooncakes.io/docs/sennenki/ignore%400.1.1), also published historically as `moonbit-community/ignore` | Gitignore-style rule parsing, path checking, and filtering; repository [zvmsbackend/ignore](https://github.com/zvmsbackend/ignore). |
| [`justjavac/glob` 0.2.0](https://mooncakes.io/docs/justjavac/glob%400.2.0) | Path-aware `?`, `*`, `**`, validation and escaping; repository [moonbit-glob](https://github.com/justjavac/moonbit-glob). |
| [`Lxxbv/glob` 0.2.6](https://mooncakes.io/docs/Lxxbv/glob%400.2.6) | Compiled globs, file search, include/exclude queries, ignore rules, a path index, explanations and caching; repository [Lxxbv/glob](https://github.com/Lxxbv/glob). |
| [`moonbitstack/moonregex/glob`](https://mooncakes.io/docs/moonbitstack/moonregex%400.2.1/glob) | Glob/GlobSet and fnmatch-style helpers with classes, alternatives and case options; repository [moonregex](https://github.com/moonbitstack/moonregex). |
| [Community `globset-lite` task](https://github.com/moonbit-community/auto-contrib-workflow/issues/6) | A compiled multipattern matcher with pattern IDs and diagnostics, explicitly excluding ignore parsing and filesystem traversal. |

These findings ruled out claiming a generic glob engine, ignore matcher,
explainable file search, or directory scanner as the project's distinctive
contribution. No benchmark or correctness superiority over those packages is
asserted without a like-for-like measurement.

## Chosen incremental contribution

MoonPathspec's completion target is the complete public pathspec matching
semantics of Git 2.43.0 and 2.56.0 over caller-supplied UTF-8 paths and attributes.
The historical GPP-1 contract is not retained as a restricted completion target.
Current implementation and verification status is stated separately in
[the compatibility document](COMPATIBILITY.md). The intended independent pure
MoonBit delivery combines:

- Structured supported short/long magic, incompatibility checks, and precise
  UTF-8 byte diagnostics.
- Backslash escapes mixed with active wildcards, exact-name fallback before
  wildcard evaluation, byte-prefix magic and explicit global settings.
- Distinct default and `glob` wildcard semantics, root anchoring, and an explicit
  caller prefix rather than a global host current directory.
- Attribute predicates over all four attribute states through a callback.
- Positive/exclusion composition with per-candidate evidence of which pattern
  indices affected the result.
- Bounded iterative byte matching and explicit resource-exhaustion errors.
- Independent Git differential fixtures, separately counted profile rejections,
  and an inspectable compatibility boundary.

Resource/input validation cases are distinct from valid-pattern equivalence
cases. A valid syntax gap must be fixed and tested, not recategorized as a
permanent profile rejection. Native POSIX verification is not inferred from a
Windows top-mode observation.

This is an incremental engineering claim, not an assertion that each individual
item is new to all software or unique within MoonBit. Its value must be assessed
from the actual interfaces, implementation, tests, and documented limits. Git
is an oracle used during testing; shelling out to Git is not the runtime
implementation. The parser, matcher, and selection logic are not moved into
the JavaScript/Python host adapters.

## Distinction from the completed October project

The completed October CatalogGuard project concerns PO/POT catalogs, formatting,
HTML/XML structure, and translation consistency across files. MoonPathspec
selects supplied repository-relative paths using pathspec semantics. It does
not inspect translation content, validate catalog documents, or produce a new
directory-audit product under a different name. The matching and selection
core is newly written for this project; no CatalogGuard code is required by
its public contract.

Git's glossary, upstream tests, and inspected existing MoonBit sources informed
requirements and independent expectations. Their implementation has not been
copied into the MoonPathspec core. This comparison is research and development
documentation, not a separate contest submission attachment. It does not claim
publication, successful organizer review, or an unconfirmed line-count threshold.
