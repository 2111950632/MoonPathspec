///|
fn parser_expect_ok(source : String) -> ParsedPattern {
  match parse_pattern(source) {
    Ok(parsed) => parsed
    Err(error) =>
      abort("unexpected parse failure: \{error.code} at \{error.offset}")
  }
}

///|
fn parser_expect_error(
  source : String,
  code : String,
  offset : Int32,
) -> Unit raise {
  match parse_pattern(source) {
    Ok(_) => abort("expected parse failure")
    Err(error) => {
      assert_eq(error.code, code)
      assert_eq(error.offset, offset)
      assert_true(error.message.length() > 0)
    }
  }
}

///|
test "ordinary patterns preserve every body character" {
  for
    source in [
      "src/*.mbt", "./a/../b", "文档/🛰️.txt", "!literal", " ", "a\\b",
    ] {
    let parsed = parser_expect_ok(source)
    assert_eq(parsed.original, source)
    assert_eq(parsed.pattern, source)
    assert_false(parsed.no_pathspec)
    assert_eq(parsed.magic, {
      top: false,
      literal: false,
      glob: false,
      icase: false,
      exclude: false,
      attributes: [],
    })
  }
}

///|
test "the bare colon sentinel is distinct from an empty magic body" {
  let sentinel = parser_expect_ok(":")
  assert_true(sentinel.no_pathspec)
  assert_eq(sentinel.pattern, "")
  for source in [":()", ":(top)", ":(exclude)", ":/", ":!", ":^", "::"] {
    let parsed = parser_expect_ok(source)
    assert_false(parsed.no_pathspec)
    assert_eq(parsed.pattern, "")
  }
}

///|
test "long magic combines supported flags" {
  let parsed = parser_expect_ok(":(top,glob,icase,exclude)src/**/a?.mbt")
  assert_eq(parsed.pattern, "src/**/a?.mbt")
  assert_eq(parsed.magic, {
    top: true,
    literal: false,
    glob: true,
    icase: true,
    exclude: true,
    attributes: [],
  })
  let literal = parser_expect_ok(":(literal,top)src/a[1].mbt")
  assert_true(literal.magic.literal)
  assert_true(literal.magic.top)
  assert_eq(literal.pattern, "src/a[1].mbt")
}

///|
test "Git permits repeated flags and empty long magic entries" {
  let parsed = parser_expect_ok(":(,top,,top,icase,icase,)x")
  assert_true(parsed.magic.top)
  assert_true(parsed.magic.icase)
  assert_eq(parsed.pattern, "x")
  let empty = parser_expect_ok(":(,,):name")
  assert_eq(empty.pattern, ":name")
}

///|
test "short magic combines root and exclude with an optional delimiter" {
  for source in [":/!src", ":!/src", ":/^src", ":^/src", ":/!^:src", ":!!/src"] {
    let parsed = parser_expect_ok(source)
    assert_eq(parsed.pattern, "src")
    assert_true(parsed.magic.top)
    assert_true(parsed.magic.exclude)
  }
  assert_eq(parser_expect_ok(":foo").pattern, "foo")
  assert_eq(parser_expect_ok("::foo").pattern, "foo")
  assert_eq(parser_expect_ok(":/::foo").pattern, ":foo")
  assert_eq(parser_expect_ok(":():foo").pattern, ":foo")
}

///|
test "glob and regex punctuation terminate the short magic signature" {
  // Independently checked with git ls-files, Git 2.56.0.windows.4.
  for
    body in [
      "?foo", "*foo", "+foo", ".foo", "$foo", ")foo", "{foo", "|foo", "}foo", "[foo",
      "]foo", "\\foo",
    ] {
    let parsed = parser_expect_ok(":" + body)
    assert_eq(parsed.pattern, body)
  }
}

///|
test "the short delimiter allows reserved punctuation in the body" {
  for body in ["@foo", "#foo", "-foo", "!foo", "_foo", ":foo"] {
    assert_eq(parser_expect_ok("::" + body).pattern, body)
  }
}

///|
test "attribute requirements preserve all four states" {
  let parsed = parser_expect_ok(
    ":(top,attr:ready -binary !vendored lang=moonbit)src/**",
  )
  assert_true(parsed.magic.top)
  assert_eq(parsed.pattern, "src/**")
  assert_eq(parsed.magic.attributes, [
    IsSet("ready"),
    IsUnset("binary"),
    IsUnspecified("vendored"),
    Equals("lang", "moonbit"),
  ])
}

///|
test "attribute name and value edge cases match the Git probe" {
  let parsed = parser_expect_ok(
    ":(attr: .name_1-X  -binary !none empty= code=Ab_09-Z )x",
  )
  assert_eq(parsed.magic.attributes, [
    IsSet(".name_1-X"),
    IsUnset("binary"),
    IsUnspecified("none"),
    Equals("empty", ""),
    Equals("code", "Ab_09-Z"),
  ])
  assert_eq(parser_expect_ok(":(attr:   )x").magic.attributes, [])
  assert_eq(parser_expect_ok(":(attr:a a)x").magic.attributes, [
    IsSet("a"),
    IsSet("a"),
  ])
  assert_eq(parser_expect_ok(":(attr:a=x\\y)x").magic.attributes, [
    Equals("a", "xy"),
  ])
  assert_eq(parser_expect_ok(":(attr,attr)x").magic.attributes, [])
  assert_eq(parser_expect_ok(":(attr,attr:a,attr)x").magic.attributes, [
    IsSet("a"),
  ])
}

///|
test "UTF8 offsets and Unicode bodies are independent of UTF16 indexing" {
  assert_eq(
    parser_expect_ok(":(top)文档/🛰.txt").pattern,
    "文档/🛰.txt",
  )
  assert_eq(parser_expect_ok(":(top)\u{FEFF}x").pattern, "\u{FEFF}x")
  parser_expect_error("文🛰\u{0000}tail", "nul_byte", 7)
  parser_expect_error(":(attr:a=值)x", "invalid_attribute", 9)
  parser_expect_error(":(attr:a 中文)x", "invalid_attribute", 9)
}

///|
test "malformed magic fails explicitly" {
  parser_expect_error("", "empty_pattern", 0)
  parser_expect_error(":(top", "unclosed_magic", 1)
  parser_expect_error(":(top,unknown)x", "unknown_magic", 6)
  parser_expect_error(":(prefix:2x)x", "invalid_prefix_magic", 10)
  parser_expect_error(":(TOP)x", "unknown_magic", 2)
  parser_expect_error(":(top, icase)x", "unknown_magic", 6)
  parser_expect_error(":(literal,glob)x", "conflicting_magic", 10)
  parser_expect_error(":(glob,literal)x", "conflicting_magic", 7)
  parser_expect_error(":(attr:a,attr:b)x", "invalid_attribute", 9)
  parser_expect_error(":(attr:)x", "invalid_attribute", 7)
}

///|
test "unknown short magic symbols fail at their byte position" {
  for
    symbol in [
      "@", "#", "%", "&", "\"", "'", ",", "-", ";", "<", "=", ">", "_", "`", "~",
    ] {
    parser_expect_error(":" + symbol + "foo", "unknown_magic", 1)
    parser_expect_error(":/!" + symbol + "foo", "unknown_magic", 3)
  }
}

///|
test "malformed attribute requirements do not become ordinary patterns" {
  parser_expect_error(":(attr:-)x", "invalid_attribute", 8)
  parser_expect_error(":(attr:!)x", "invalid_attribute", 8)
  parser_expect_error(":(attr:--a)x", "invalid_attribute", 8)
  parser_expect_error(":(attr:-a=x)x", "invalid_attribute", 9)
  parser_expect_error(":(attr:!a=x)x", "invalid_attribute", 9)
  parser_expect_error(":(attr:a+b)x", "invalid_attribute", 8)
  parser_expect_error(":(attr:a\tb)x", "invalid_attribute", 8)
  parser_expect_error(":(attr:a\nb)x", "invalid_attribute", 8)
  for value in ["x.y", "x/y", "x:y", "x+y", "x@y", "x=y", "x*y"] {
    parser_expect_error(":(attr:a=" + value + ")x", "invalid_attribute", 10)
  }
  parser_expect_error(":(attr:a=x\\)x", "unclosed_magic", 1)
}

///|
test "long magic delimiter scanning preserves escaped attribute commas" {
  // Git 2.56.0.windows.4: mark=one,two from check-attr is selected by this
  // escaped value; an escaped ')' passes scanning but fails value validation.
  let parsed = parser_expect_ok(":(top,attr:mark=one\\,two,icase)a")
  assert_eq(parsed.pattern, "a")
  assert_true(parsed.magic.top)
  assert_true(parsed.magic.icase)
  assert_eq(parsed.magic.attributes, [Equals("mark", "one,two")])
  parser_expect_error(":(attr:mark=one\\)two)a", "invalid_attribute", 16)
  parser_expect_error(":(attr:mark=one,two)a", "unknown_magic", 16)
}

///|
test "prefix magic retains Git signed decimal syntax and last value" {
  // Independently checked with Git 2.56.0.windows.4. A prefix larger than the
  // body is parsed here but safely rejected by the compiler, not a Git BUG.
  for
    source in [
      ":(prefix:0)a", ":(prefix:)a", ":(prefix:+0)a", ":(prefix: 0)a", ":(prefix:-0)a",
    ] {
    assert_eq(parser_expect_ok(source).prefix_length, Some(0))
  }
  assert_eq(parser_expect_ok(":(prefix:-1)a").prefix_length, None)
  assert_eq(parser_expect_ok(":(prefix:1)a").prefix_length, Some(1))
  assert_eq(parser_expect_ok(":(prefix:0,prefix:1)a").prefix_length, Some(1))
  assert_eq(parser_expect_ok(":(prefix:1,prefix:-1)a").prefix_length, None)
  assert_eq(parser_expect_ok(":(prefix:4,icase)文/a").pattern, "文/a")
  parser_expect_error(":(prefix:+)a", "invalid_prefix_magic", 9)
  parser_expect_error(":(prefix:0 )a", "invalid_prefix_magic", 10)
  parser_expect_error(":(prefix:2147483648)a", "invalid_prefix_magic", 18)
  parser_expect_error(":(prefix:-2147483649)a", "invalid_prefix_magic", 19)
}

///|
fn parser_with_options(
  source : String,
  options : PathspecOptions,
) -> ParsedPattern {
  match parse_pattern_options(source, options) {
    Ok(value) => value
    Err(error) => abort("unexpected options parse error: \{error.code}")
  }
}

///|
test "global literal ignores magic while noglob retains per-pattern local_modes" {
  let literal = { ..default_pathspec_options(), literal: true, }
  let source = ":(unknown)*[1]"
  let parsed = parser_with_options(source, literal)
  assert_eq(parsed.pattern, source)
  assert_true(parsed.magic.literal)
  assert_false(parsed.magic.top)
  assert_eq(parsed.magic.attributes, [])
  assert_eq(parsed.prefix_length, None)
  let colon = parser_with_options(":", literal)
  assert_eq(colon.pattern, ":")
  assert_false(colon.no_pathspec)
  let noglob = { ..default_pathspec_options(), noglob: true, }
  assert_true(parser_with_options("a*", noglob).magic.literal)
  let local_mode = parser_with_options(":(top,glob)a*", noglob)
  assert_true(local_mode.magic.top)
  assert_true(local_mode.magic.glob)
  assert_false(local_mode.magic.literal)
  let allowed = parser_with_options("a", { ..literal, noglob: true, })
  assert_true(allowed.magic.literal)
}

///|
test "global glob and icase merge with explicit literal local_mode" {
  let options = { ..default_pathspec_options(), glob: true, icase: true, }
  let plain = parser_with_options("a*", options)
  assert_true(plain.magic.glob)
  assert_true(plain.magic.icase)
  assert_false(plain.magic.literal)
  let local_mode = parser_with_options(":(literal)a*", options)
  assert_true(local_mode.magic.literal)
  assert_true(local_mode.magic.icase)
  assert_false(local_mode.magic.glob)
  let windows = parser_with_options("a\\*", { ..options, windows: true, })
  assert_eq(windows.pattern, "a\\*")
}

///|
test "global option conflicts match Git instead of silently changing precedence" {
  for
    options in [
      { ..default_pathspec_options(), glob: true, noglob: true, },
      { ..default_pathspec_options(), literal: true, glob: true, },
      { ..default_pathspec_options(), literal: true, icase: true, },
    ] {
    assert_true(parser_options_error(options) is Some(_))
    match parse_pattern_options("a", options) {
      Err(error) => assert_eq(error.code, "conflicting_options")
      Ok(_) => abort("expected conflicting global options")
    }
  }
}

///|
test "NUL is rejected anywhere including magic and bodies" {
  parser_expect_error("\u{0000}", "nul_byte", 0)
  parser_expect_error(":(to\u{0000}p)x", "nul_byte", 4)
  parser_expect_error(":(top)x\u{0000}", "nul_byte", 7)
}
