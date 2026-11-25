# Development

Implement selection semantics in MoonBit. Host code may read files, pass requests,
and print responses; it must not parse patterns, match paths, or evaluate attributes.
Do not modify the completed October CatalogGuard project.

Target the complete public pathspec grammar/matching semantics of Git 2.43.0
and 2.56.0 for supplied UTF-8 repository-relative candidate files and typed
attributes. GPP-1 is the historical 0.1.x scope, not a completion endpoint.
Do not hide a legal-syntax gap behind a new restricted compatibility profile.
Default to POSIX preprocessing and expose Windows preprocessing explicitly.

Use explicit limits and error results. Malformed wildcard matching may be a
successful nonmatch or raw-name match in Git; do not turn it into a new syntax
error. Invalid magic, conflicting settings and resource failures remain errors.
Tests must have independently obtained expectations, including Git differential
checks. Preserve distinctions between research fixtures, current implementation
tests, successful local verification, publication and organizer approval.

Run moon check, both JS/Wasm GC tests, moon fmt --check and moon info after core
changes. Review generated interfaces. Do not claim full Git command compatibility
or arbitrary non-UTF-8 filenames. Record sources and any copied code separately.
