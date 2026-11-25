# Git pathspec compatibility target

## Completion target and version references

The completion target is the **complete public pathspec syntax and matching
semantics of Git 2.43.0 and Git 2.56.0** over caller-supplied UTF-8,
repository-relative candidate files and typed attributes. GPP-1 describes the
historical 0.1.x implementation only. It is not the completion target for the
current work, and a new restricted profile must not replace the public target.

The public references and fixed implementation references are:

| Version | Syntax and global settings | Semantic reference |
| --- | --- | --- |
| Git 2.43.0 | [glossary](https://github.com/git/git/blob/v2.43.0/Documentation/glossary-content.txt#def_pathspec), [git options](https://github.com/git/git/blob/v2.43.0/Documentation/git.txt) | [pathspec.c](https://github.com/git/git/blob/v2.43.0/pathspec.c), [dir.c](https://github.com/git/git/blob/v2.43.0/dir.c), [wildmatch.c](https://github.com/git/git/blob/v2.43.0/wildmatch.c), [parse.c](https://github.com/git/git/blob/v2.43.0/parse.c) |
| Git 2.56.0 | [glossary](https://github.com/git/git/blob/v2.56.0/Documentation/glossary-content.adoc#def_pathspec), [git options](https://github.com/git/git/blob/v2.56.0/Documentation/git.adoc) | [pathspec.c](https://github.com/git/git/blob/v2.56.0/pathspec.c), [dir.c](https://github.com/git/git/blob/v2.56.0/dir.c), [wildmatch.c](https://github.com/git/git/blob/v2.56.0/wildmatch.c), [parse.c](https://github.com/git/git/blob/v2.56.0/parse.c) |

Sources establish intended semantics, not that the current implementation has
passed every case. Where glossary shorthand and observed matching behavior
differ, retain the concrete fixed-version result in independent differential
tests. Do not substitute intuitive shell matching, a generic regular-expression
engine, or a stricter grammar.

## Input model and external responsibilities

The library receives candidate file paths, a current-directory prefix, patterns
and an optional attribute callback. Candidate order is preserved. The core owns
parsing, matching, prefix/mode handling, attribute predicates, resource accounting,
selection and explanations.

The caller owns candidate discovery, conversion of physical paths to repository
paths, Git index/tree/worktree membership, symlink discovery, filesystem casing,
submodule enumeration, and attribute-file parsing and inheritance. A Git command
adapter must supply that command's candidate set and worktree-derived attribute
states. This separation does not exclude valid pattern syntax from the target.

The String API represents UTF-8 paths, not arbitrary non-UTF-8 filename bytes; a
future byte API is a separate representation concern. That boundary is not
permission to reject backslash escapes or literal wildcard characters in UTF-8
inputs. Candidates are canonical relative file paths using `/`; duplicate,
empty, NUL, absolute and `.`/`..` candidate components fail validation.

## Required matching semantics

| Area | Target behavior |
| --- | --- |
| Raw path matching | Retain Git's exact-name and descendant comparison before wildcard evaluation. A raw name containing `[`, `*` or `?` can match itself as well as another name through wildcards. |
| Default wildcards | Default `*` and `?` may consume directory separators. Current-directory preprocessing and path scope follow pathspec, not gitignore rules. |
| Glob magic | Ordinary wildcard tokens do not consume `/`. Recursive star components, zero-directory `**/`, trailing `/**`, repeated stars and escaped separators follow the fixed Git matcher behavior. |
| Escapes | Backslash quotes the following byte during wildcard matching, including literal `[ ] ? *` mixed with active wildcards. An escape after a star is not a reason to reject the pattern. Literal magic instead treats the whole body literally. |
| Character classes | Byte sets, negation, ranges, escaped members and C-locale POSIX classes follow Git. Unclosed or malformed classes and descending ranges retain raw-name fallback and Git's wildcard result; they do not become new compile errors. |
| Magic | Short forms and optional delimiter; long top/literal/glob/icase/exclude/attr; repeated and empty words where accepted; unknown/conflicting magic errors. Escaped delimiters are scanned before attribute values are unescaped and validated. |
| Prefix | Separate current-directory prefix, non-top navigation within repository scope, top root anchoring, and accepted `prefix:N` as a byte count with root-context validation and a case-sensitive protected prefix. |
| Case | ASCII/C-locale byte rules, including distinct singleton/range/POSIX-class behavior. Protected prefix bytes are not case-folded. This is not Unicode normalization. |
| Attributes | Set, Unset, Unspecified and Value are distinct. All ATTR/-ATTR/!ATTR/ATTR=VALUE conditions must pass. Accepted value escapes include a comma. Missing callback means Unspecified. |
| Composition | Positive union followed by all exclusions. Exclusion-only input starts within the caller prefix. Bare `:` and combinations are tested against the recorded command/version. |
| Failure | Git-invalid magic/settings are structured errors. Wildcard failure remains nonmatch; resource exhaustion remains error. No partial successful selection is returned on failure. |

Concrete expectations are in the [13-case escaped-pattern
suite](../examples/escaped-pathspec/README.md). API strings, JSON escaping and
shell quoting are separate layers. Synthetic Windows-illegal worktree names may
be staged directly in an independent index; this does not claim NTFS supports
creating those files.

## POSIX and Windows path preprocessing

`default_pathspec_options()` selects POSIX semantics on every host. Strings are
the pattern bytes after shell argument parsing, not shell source text. A Windows
host must not silently turn backslash escapes into separators.

`options.windows=true` (CLI `--path-mode windows`) explicitly requests Windows
Git-style preprocessing. Non-top bodies and caller prefix receive separator
treatment; top and explicit `prefix:N` retain the body where the fixed baseline
does so. Candidates remain repository paths with `/`. This mode is checked
separately against Windows Git. Native Linux Git must verify POSIX non-top
cases; top-mode Windows observations cannot be relabeled as a Linux run.

## Global settings and environment

The public `PathspecOptions` record contains `literal`, `glob`, `noglob`, `icase`
and `windows`. The library takes explicit values and never reads process
environment variables. The JSON bridge accepts only these Boolean fields in
`options`. `inspect` returns merged settings and each pattern's `prefix_length`.

| Setting | Effect |
| --- | --- |
| Global literal | Disable wildcard and magic interpretation, including a leading colon. |
| Global glob | Apply glob except where local literal overrides it. |
| Global noglob | Apply literal except where local glob overrides it; local magic is still parsed. |
| Global icase | Combine case-insensitive matching with other accepted modes. |

Global glob/noglob conflict. Global literal conflicts with global glob or icase;
literal plus noglob is accepted. Local literal/glob still conflict. Positive and
negative CLI flags set their corresponding field; its last explicit value wins.

The host may transport four original strings, `GIT_LITERAL_PATHSPECS`,
`GIT_GLOB_PATHSPECS`, `GIT_NOGLOB_PATHSPECS` and `GIT_ICASE_PATHSPECS`, in the
JSON `environment` object. MoonBit parses case-insensitive true/yes/on and
false/no/off, empty false, and Git's signed Int32 base-zero integers with optional
k/m/g factors. Nonzero means true. Unknown names, non-string values, malformed
numbers and overflow are errors. JSON options override corresponding raw
environment values; CLI options override JSON fields. Node transports values
and flags; it does not implement matching or Boolean conversion.

## Resource and mutability contract

Limits protect resource use without labeling legitimate syntax unsupported.
Defaults are 256 patterns, 4096 bytes per pattern, 16384 bytes per path, 100000
candidates and 2000000/20000000 match/selection work units. Hard ceilings are
4096 patterns, 65536 bytes per pattern/path, 1000000 candidates and
100000000/200000000 work units. Aggregate patterns are capped at 1 MiB; compiled
state at 65536 units. A token costs one and a class with its bitsets seventeen.

Matching uses iterative DP rather than exponential backtracking. Steps are
deterministic work units, not CPU instructions or a whole-process memory/time
guarantee. Input conversion, validation and callback work are not DP cells.
JSON input is limited to 16 MiB/depth 64; batches to 256 requests/200000000 units.
Matching exhaustion stops without partial batch results.

Selection snapshots candidates before validation and callbacks. Replacing,
appending or clearing the caller array cannot alter that in-flight selection.
Attribute values remain caller-controlled; reproducible callers must provide a
stable, terminating callback.

## Current verification status

The [0.2.0 local record](../evidence/validation-0.2.0.json) passed 74 core
cases on each JS/Wasm GC backend, 40 Node cases, 13 runnable examples, and 7
own public-API cases per backend from the actual extracted package. Native
Windows Git 2.56.0 passed 444 general differential cases and 352 extended
escape/settings cases. Seven POSIX-only cases were not run there and are not
counted as passed.

Native Linux Git 2.43.0 and 2.56.0, the online platform matrix and 0.2.0 registry
publication/download remain pending. The workflow source is not execution
proof. Historical 0.1.x evidence retains its original scope. Implementation
tests, independent Git runs, package extraction, actual network download and
organizer review are separate claims. A finite suite is evidence for its
recorded inputs and versions, not a proof of every possible pathspec. Remaining
legal-syntax gaps must be fixed, not converted to permanent profile exclusions.
