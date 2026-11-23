# Ecosystem comparison and incremental scope

Research date: 2026-11-23. This comparison identifies observed overlap and the
specific scope chosen for MoonPathspec. It is not a claim that the MoonBit
ecosystem has no similar code. Search indexing, package summaries, and current
branches can change; an absent search result is not proof of absence.

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

MoonPathspec implements the bounded [GPP-1 contract](COMPATIBILITY.md): an
independent pure MoonBit core for Git pathspec file selection over caller-supplied
paths and attributes. Its incremental scope is the combination of:

- Structured supported short/long magic, incompatibility checks, and precise
  UTF-8 byte diagnostics.
- Distinct default and `glob` wildcard semantics, root anchoring, and an explicit
  caller prefix rather than a global host current directory.
- Attribute predicates over all four attribute states through a callback.
- Positive/exclusion composition with per-candidate evidence of which pattern
  indices affected the result.
- Bounded iterative byte matching and explicit resource-exhaustion errors.
- Independent Git differential fixtures, separately counted profile rejections,
  and an inspectable compatibility boundary.

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
