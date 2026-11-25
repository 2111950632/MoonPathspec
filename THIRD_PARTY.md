# Sources and licenses

MoonPathspec's matching, magic parsing, selection and reporting code is newly
written in MoonBit. AI assisted development; the maintainer is responsible for
review, validation and maintenance. No third-party matcher implementation was
copied. Git terminology and specified behavior are used as compatibility facts.

| Source | Use |
|---|---|
| [MoonBit core](https://github.com/moonbitlang/core), Apache-2.0 | Standard-library UTF-8, JSON and debugging; retain NOTICE with compiled distributions. |
| [Git glossary](https://git-scm.com/docs/gitglossary#def_pathspec) | Public pathspec semantics and terminology. |
| [Git](https://github.com/git/git), GPL-2.0 | An independently installed command-line oracle in tests. No implementation or upstream test files are redistributed. |
| [bit](https://github.com/bit-vcs/bit) | Existing ecosystem baseline, inspected to describe overlap and net additions. No source copied or bundled. |

All checked-in fixture paths and test input data are synthetic, authored for this
project. Tests generate their own temporary Git index and attributes. The
runtime does not depend on Git, Python, Node packages, bit, or a Git index.
The optional Node.js CLI needs Node.js itself. Python and Git are only used by
the independent verification suite. The Apache-2.0 project license does not
relicense external standards, tools or their documentation.

## Fixed Git compatibility references for 0.2.0

The complete public pathspec grammar/matching target uses Git tags
[v2.43.0](https://github.com/git/git/tree/v2.43.0) and
[v2.56.0](https://github.com/git/git/tree/v2.56.0). The glossary, Git global
options, pathspec.c, dir.c, wildmatch.c and parse.c inform independently written
MoonBit behavior. Upstream t6130/t6137 test concepts informed synthetic escaped
path examples; no upstream test scripts or matcher code are copied.

CI builds the two GPL-2.0 Git references from official kernel.org tarballs in a
temporary directory. Pinned SHA-256 values and URLs are recorded in
`scripts/build-reference-git.sh`; this is an integrity check, not a claim to
have verified PGP signatures. Git is only an external test command. Its source
and executable are not included in the Mooncakes package or Node distribution.
Fixture expectations are measured through real Git index/check-attr queries.
