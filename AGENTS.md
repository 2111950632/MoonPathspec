# Development

Implement selection semantics in MoonBit. Host code may read files, pass requests,
and print responses; it must not parse patterns, match paths, or evaluate attributes.
Do not modify the completed October CatalogGuard project.

Use explicit limits and error results. Unsupported behavior must fail visibly.
Tests must have independently obtained expectations, including Git differential
checks. Preserve distinctions between research fixtures, current implementation
tests, successful local verification, publication and organizer approval.

Run moon check, both JS/Wasm GC tests, moon fmt --check and moon info after core
changes. Review generated interfaces. Do not claim full Git command compatibility
or arbitrary non-UTF-8 filenames. Record sources and any copied code separately.
