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
