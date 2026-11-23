# GPP-1 compatibility profile

GPP-1 is MoonPathspec's bounded, UTF-8 repository-relative file-selection
profile. It is a library contract, not a claim of compatibility with every Git
command, every filesystem, or every pathspec accepted by Git.

The core takes a list of candidate file paths, an optional current-directory
prefix, patterns, and an attribute callback. It returns a selection and
per-candidate explanations. The caller owns discovery of candidates and
attributes. The core does not read a Git index, walk a worktree, resolve symlinks,
read Git configuration, or parse `.gitattributes`. Git is used by the test oracle,
not by the matching implementation.

## Reference and measured baseline

The normative reference is the Git glossary's
[pathspec definition](https://git-scm.com/docs/gitglossary#def_pathspec).
Related upstream regression sources include
[literal/wildcard mode](https://github.com/git/git/blob/master/t/t6130-pathspec-noglob.sh),
[icase](https://github.com/git/git/blob/master/t/t6131-pathspec-icase.sh),
[exclusions](https://github.com/git/git/blob/master/t/t6132-pathspec-exclude.sh),
[attributes](https://github.com/git/git/blob/master/t/t6135-pathspec-with-attrs.sh),
and [literal wildcard characters](https://github.com/git/git/blob/master/t/t6137-pathspec-wildcards-literal.sh).
Links to moving upstream branches are reference material, not frozen test results.

The locally measured command-line baseline is **Git
2.56.0.windows.4**. `tests/git_oracle.py` stages its own UTF-8 fixture paths and
compares against `git ls-files --full-name -z -- <patterns>`. Attribute evidence
comes from `git check-attr -z`, retaining Set, Unset, Unspecified, and string Value
as separate states. Expected Git sets are restored to the caller's candidate
order before comparison. The script records its Git version in the generated
report; later runs may establish another measured baseline.

Windows Git's command-line path preprocessing can interpret backslashes as path
separators. Such observations must not be described as direct execution of
Unix-style backslash-escape matching. The report distinguishes equivalence
checks from explicitly rejected profile inputs. Research observations retain
Git's actual result even when MoonPathspec deliberately rejects the input.
Passing a fixture establishes the behavior of that fixture and baseline; it is
not a proof of all possible pathspec behavior. Consult the current generated
report for actual pass/fail counts.

## Supported contract

| Area | GPP-1 behavior |
| --- | --- |
| Candidate paths | UTF-8 file paths relative to a repository root; `/` separates components. Candidates must be canonical and unique. Input order is preserved. |
| Prefix | A separate repository-relative current-directory prefix. Non-top patterns may navigate within the repository; attempts to leave its root fail. `top` anchors at the repository root and retains its raw body instead of applying current-directory path normalization. The caller's prefix is not itself case-folded by `icase`. |
| Magic | Long-form `top`, `literal`, `glob`, `icase`, `exclude`, `attr:` and supported short signatures. Unknown magic and incompatible `literal,glob` fail explicitly. |
| Default wildcards | `*` and `?` may consume `/`. Bracket expressions operate on bytes. |
| Glob magic | Ordinary `*`, `?`, and bracket expressions do not consume `/`. A complete component of two or more stars is recursive; `**/` also consumes zero directories. A trailing `/**` consumes descendants. |
| Non-component repeated stars | Ordinary non-recursive stars in glob mode. This follows the measured Git baseline rather than rejecting every placement discouraged by the glossary. |
| Literal patterns | Metacharacters remain literal under `literal` magic. Literal directory names select supplied descendants; the library does not enumerate those descendants. |
| Exclusion | Positive patterns form the initial set, then all matching exclusions remove paths. An exclusion-only list starts from the prefix's candidate scope. This is not `.gitignore`'s last-matching-rule model. |
| Bare `:` | A prefix-scoped all-paths positive entry, including when combined with other positive patterns. Its measured `ls-files` behavior is recorded separately from the glossary's advice against mixing it. |
| `icase` | ASCII byte case behavior. There is no Unicode case folding or normalization. Bracket singleton, range, and POSIX-class behavior are represented separately to retain Git's observed distinctions. |
| Attributes | `ATTR`, `-ATTR`, `!ATTR`, and `ATTR=VALUE` query the callback's typed state. All conditions on a pattern must pass. An absent callback reports Unspecified. The core does not substitute tree-object attributes for worktree attributes. |
| Explanations | Include/exclude pattern indices, decision reason, and bounded work accounting are returned from the same selection evaluation. |
| Errors | Structured errors carry their applicable pattern/path index and zero-based UTF-8 byte offset. A failed or budget-exhausted match is not returned as a successful negative decision. |

For example, default `doc/*.jpg` can select both `doc/a.jpg` and
`doc/sub/b.jpg`. `:(glob)doc/*.jpg` selects only the former. Under the measured
baseline, `:(icase,glob)[A]` and `:(icase,glob)[A-Z]` have different behavior;
GPP-1 does not replace bracket matching with a generic Unicode case-insensitive
regular expression.

`?` consumes one UTF-8 byte, not one Unicode scalar or grapheme. Thus one `?`
does not match the two-byte encoding of `é`. This byte behavior does not imply
support for arbitrary non-UTF-8 filenames: the public inputs are MoonBit strings.

## Explicit boundaries

GPP-1 excludes arbitrary non-UTF-8 filenames, absolute/drive/UNC path resolution,
host filesystem case rules, Unicode folding, repository discovery, tracked versus
untracked classification, sparse indexes, submodule traversal, symlink traversal,
revision/path ambiguity, command-specific pathspec options, and environment
variables such as `GIT_LITERAL_PATHSPECS`. These belong in adapters or future
separately tested profiles.

Candidates, prefixes and pattern bodies starting with `/`, a backslash, or an
ASCII drive designator such as `C:` are rejected on every backend. This also
excludes drive-relative forms and otherwise legal Unix filenames with that
spelling; they are not silently treated as portable repository paths.

The wildcard parser reports unterminated bracket expressions, dangling escapes,
descending byte ranges, unknown POSIX class names, collating symbols, and
equivalence classes as explicit errors. It supports the ASCII/C-locale classes
`alnum`, `alpha`, `blank`, `cntrl`, `digit`, `graph`, `lower`, `print`, `punct`,
`space`, `upper`, and `xdigit`. A POSIX class cannot be used as a range endpoint.
These strict diagnostics are part of GPP-1; they are not a claim that every Git
version diagnoses those inputs in the same way.

Any backslash in a **non-literal pattern body** is rejected publicly with
`unsupported_backslash`. Use `:(literal)` to select filenames containing wildcard
metacharacters instead of relying on backslash escapes. This is a deliberate
cross-platform profile boundary: Windows Git command-line path preprocessing
must not be mistaken for Unix wildcard escape matching. Escapes inside attribute
magic values are parsed by the magic parser and are a separate grammar.

The internal matcher retains escape decoding so that literal-mode compilation
can quote metacharacters without a host regular-expression engine. Its
`unsupported_glob_escape` diagnostic for a star immediately followed by an escape
is internal; public non-literal patterns encounter `unsupported_backslash`
first. Internal escape handling is not a public promise of Unix command-line
escape compatibility.

## Resource contract

Public `Limits` bound pattern count, individual and aggregate pattern bytes,
candidate count, path bytes, work per match, and total selection work. The
selector validates configured limits against hard ceilings. The wildcard core
also independently rejects patterns above 65,536 bytes and texts above 262,144
bytes. Public selection limits can be smaller.

Compiled state is capped at 65,536 units across the complete plan. Each token
costs one unit; a bracket class additionally costs sixteen units for its two
eight-word UInt32 bitsets. The compiler charges before allocating the next
token/class and returns `compile_limit` on exhaustion. This is a compile-memory
guard separate from matching work. Character classes do not allocate 512
Boolean array slots each.

The matcher uses reachable-byte-offset dynamic-programming rows, with no
recursive backtracking. Memory is proportional to the path's byte length; work
is bounded by the supplied step budget and the product of token and path counts.
One examined DP cell is one reported matching step, with an initial step for the
starting state. Step counts are deterministic work units, not elapsed-time or
whole-process memory guarantees. Compilation, UTF-8 conversion, candidate
validation, and callback work have their own bounded inputs and are not DP cells.
An attribute callback is supplied by the caller and must itself terminate.

## Implementation and evidence status

The MoonBit parser, compiler, byte matcher, selector, and explanation logic are
new implementation for this project. Git and existing MoonBit projects are
references and independent test baselines; their implementation is not copied
into this core. See [the ecosystem comparison](ECOSYSTEM.md) for the frozen
existing-project baseline and the specific incremental scope.

Current source, successful local verification, public publication, and organizer
acceptance are distinct states. This document does not assert publication or
contest acceptance, and deliberately does not freeze a dynamic test count.
