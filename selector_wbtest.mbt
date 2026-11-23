///|
fn selector_plan(
  patterns : Array[String],
  prefix~ : String = "",
  limits~ : Limits = default_limits(),
) -> Plan {
  match compile(patterns, prefix~, limits~) {
    Ok(plan) => plan
    Err(error) => abort("unexpected compile failure: \{error.code}")
  }
}

///|
test "compiled state limit bounds aggregate character class memory" {
  let patterns = Array::make(4, "[a]".repeat(1365))
  assert_eq(selector_compile_error(patterns).code, "compile_limit")
  assert_true(compile(["[a]".repeat(1365)]) is Ok(_))
}

///|
fn selector_result(
  plan : Plan,
  paths : Array[String],
  attribute~ : (String, String) -> AttributeValue = fn(_, _) { Unspecified },
) -> Selection {
  match select(plan, paths, attribute~) {
    Ok(result) => result
    Err(error) => abort("unexpected selection failure: \{error.code}")
  }
}

///|
fn selector_compile_error(
  patterns : Array[String],
  prefix~ : String = "",
  limits~ : Limits = default_limits(),
) -> SelectionError {
  match compile(patterns, prefix~, limits~) {
    Err(error) => error
    Ok(_) => abort("expected compile failure")
  }
}

///|
fn selector_select_error(
  plan : Plan,
  paths : Array[String],
  attribute~ : (String, String) -> AttributeValue = fn(_, _) { Unspecified },
) -> SelectionError {
  match select(plan, paths, attribute~) {
    Err(error) => error
    Ok(_) => abort("expected selection failure")
  }
}

///|
test "selector inclusion and exclusion preserve caller path order" {
  let plan = selector_plan(["src", ":(exclude)src/generated"])
  let result = selector_result(plan, [
    "README.md", "src/z.mbt", "src/generated/x.mbt", "src/a.mbt", "src2/a.mbt",
  ])
  assert_eq(result.selected, ["src/z.mbt", "src/a.mbt"])
  assert_eq(result.decisions[0].reason, "no_positive_match")
  assert_eq(result.decisions[1].included_by, [0])
  assert_eq(result.decisions[2].included_by, [0])
  assert_eq(result.decisions[2].excluded_by, [1])
  assert_eq(result.decisions[2].reason, "excluded_by_pattern")
  assert_false(result.decisions[2].selected)
}

///|
test "selector exclusion order does not reinclude an excluded path" {
  let paths = ["doc/a.txt", "doc/tmp/b.txt", "src/a.txt"]
  assert_eq(
    selector_result(selector_plan([":!doc/tmp", "doc"]), paths).selected,
    ["doc/a.txt"],
  )
  assert_eq(
    selector_result(selector_plan(["doc", ":!doc/tmp"]), paths).selected,
    ["doc/a.txt"],
  )
  let result = selector_result(
    selector_plan(["doc", "doc/a.txt", ":!doc/a.txt"]),
    paths,
  )
  assert_eq(result.decisions[0].included_by, [0, 1])
  assert_eq(result.decisions[0].excluded_by, [2])
  assert_eq(result.selected, ["doc/tmp/b.txt"])
}

///|
test "empty patterns and only-exclude operate within the explicit prefix" {
  let paths = [
    "root.txt", "src/a.txt", "src/ignored.txt", "src/sub/b.txt", "src2/a.txt",
  ]
  let all = selector_result(selector_plan([], prefix="src"), paths)
  assert_eq(all.selected, ["src/a.txt", "src/ignored.txt", "src/sub/b.txt"])
  assert_eq(all.decisions[1].reason, "implicit_prefix_selection")
  assert_eq(
    selector_result(selector_plan([":!ignored.txt"], prefix="src"), paths).selected,
    ["src/a.txt", "src/sub/b.txt"],
  )
  assert_eq(selector_result(selector_plan([":"]), paths).selected, paths)
}

///|
test "top magic ignores a normalized caller prefix" {
  let paths = ["root.txt", "src/a.txt", "src/sub/b.txt", "lib/a.txt"]
  let relative = selector_plan(["a.txt"], prefix="./src//sub/..")
  assert_eq(selector_result(relative, paths).selected, ["src/a.txt"])
  let top = selector_plan([":(top)root.txt"], prefix="src/sub")
  assert_eq(selector_result(top, paths).selected, ["root.txt"])
  let parent = selector_plan(["../../lib/./a.txt"], prefix="src/sub")
  assert_eq(selector_result(parent, paths).selected, ["lib/a.txt"])
}

///|
test "icase applies to the supplied pattern but not its caller prefix" {
  let paths = ["Src/A.TXT", "Src/a.txt", "src/A.TXT", "SRC/A.TXT"]
  let relative = selector_plan([":(icase)a.txt"], prefix="Src")
  assert_eq(selector_result(relative, paths).selected, [
    "Src/A.TXT", "Src/a.txt",
  ])
  let top = selector_plan([":(top,icase)src/a.txt"], prefix="elsewhere")
  assert_eq(selector_result(top, paths).selected, paths)
  let parent = selector_plan([":(icase)../A.TXT"], prefix="Src/sub")
  assert_eq(selector_result(parent, paths).selected, ["Src/A.TXT", "Src/a.txt"])
}

///|
test "literal glob and ordinary wildcard semantics remain distinct" {
  let paths = ["doc/a.jpg", "doc/sub/b.jpg", "doc/a[1].jpg", "doc/a1.jpg"]
  assert_eq(
    selector_result(selector_plan(["doc/*.jpg"]), paths).selected,
    paths,
  )
  assert_eq(
    selector_result(selector_plan([":(glob)doc/*.jpg"]), paths).selected,
    ["doc/a.jpg", "doc/a[1].jpg", "doc/a1.jpg"],
  )
  assert_eq(
    selector_result(selector_plan([":(literal)doc/a[1].jpg"]), paths).selected,
    ["doc/a[1].jpg"],
  )
  assert_eq(
    selector_result(selector_plan([":(glob)doc/**/b.jpg"]), paths).selected,
    ["doc/sub/b.jpg"],
  )
}

///|
fn selector_attribute(path : String, name : String) -> AttributeValue {
  if name != "state" {
    return Unspecified
  }
  match path {
    "set" => Set
    "unset" => Unset
    "valued" => Value("yes")
    "empty" => Value("")
    _ => Unspecified
  }
}

///|
test "attributes distinguish booleans strings empty values and unspecified" {
  let paths = ["set", "unset", "valued", "empty", "missing"]
  for
    (pattern, expected) in [
      (":(attr:state)*", ["set"]),
      (":(attr:-state)*", ["unset"]),
      (":(attr:!state)*", ["missing"]),
      (":(attr:state=yes)*", ["valued"]),
      (":(attr:state=)*", ["empty"]),
    ] {
    assert_eq(
      selector_result(
        selector_plan([pattern]),
        paths,
        attribute=selector_attribute,
      ).selected,
      expected,
    )
  }
  assert_eq(
    selector_result(selector_plan([":(attr:!state)*"]), paths).selected,
    paths,
  )
  assert_eq(
    selector_result(
      selector_plan([":(attr:state -state)*"]),
      paths,
      attribute=selector_attribute,
    ).selected,
    [],
  )
}

///|
test "attribute callbacks receive repository paths only for matching bodies" {
  let queries : Array[String] = []
  let attribute = fn(path, name) {
    queries.push(path + ":" + name)
    Set
  }
  let result = selector_result(
    selector_plan([":(attr:checked)a.txt"], prefix="src"),
    ["src/a.txt", "src/b.txt", "other/a.txt"],
    attribute~,
  )
  assert_eq(result.selected, ["src/a.txt"])
  assert_eq(queries, ["src/a.txt:checked"])
}

///|
test "compiled plans and result arrays are independent of caller arrays" {
  let patterns = ["a"]
  let plan = selector_plan(patterns)
  patterns[0] = "b"
  patterns.push(":!a")
  let paths = ["a", "b"]
  let first = selector_result(plan, paths)
  paths[0] = "changed"
  assert_eq(first.selected, ["a"])
  assert_eq(first.decisions[0].path, "a")
  first.selected.push("injected")
  first.decisions[0].included_by.push(99)
  first.decisions.push(first.decisions[0])
  let second = selector_result(plan, ["a", "b"])
  assert_eq(second.selected, ["a"])
  assert_eq(second.decisions.length(), 2)
  assert_eq(second.decisions[0].included_by, [0])
}

///|
test "explain agrees with independently specified single-path decisions" {
  let plan = selector_plan(["src", ":!src/generated"])
  match explain(plan, "src/a.mbt") {
    Err(_) => abort("expected explanation")
    Ok(decision) => {
      assert_true(decision.selected)
      assert_eq(decision.path, "src/a.mbt")
      assert_eq(decision.included_by, [0])
      assert_eq(decision.excluded_by, [])
      assert_eq(decision.reason, "included_by_pattern")
      assert_true(decision.steps > 0)
    }
  }
  match explain(plan, "src/generated/x.mbt") {
    Err(_) => abort("expected explanation")
    Ok(decision) => {
      assert_false(decision.selected)
      assert_eq(decision.excluded_by, [1])
    }
  }
}

///|
test "compile errors retain source pattern indexes and UTF8 offsets" {
  let error = selector_compile_error(["valid", ":(attr:a=值)x"])
  assert_eq(error.code, "invalid_attribute")
  assert_eq(error.pattern_index, Some(1))
  assert_eq(error.path_index, None)
  assert_eq(error.offset, Some(9))
  let outside = selector_compile_error(["ok", "../../x"], prefix="src")
  assert_eq(outside.code, "outside_repository")
  assert_eq(outside.pattern_index, Some(1))
  assert_eq(selector_compile_error(["/absolute"]).code, "outside_repository")
  assert_eq(
    selector_compile_error(["a"], prefix="../src").code,
    "invalid_prefix",
  )
}

///|
test "colon selects the current prefix without compressing pattern indexes" {
  let first = selector_result(selector_plan([":", "a"]), ["a", "b"])
  assert_eq(first.selected, ["a", "b"])
  assert_eq(first.decisions[0].included_by, [0, 1])
  assert_eq(first.decisions[1].included_by, [0])
  let last = selector_result(selector_plan(["a", ":"]), ["a", "b"])
  assert_eq(last.selected, ["a", "b"])
  assert_eq(last.decisions[0].included_by, [0, 1])
  assert_eq(last.decisions[1].included_by, [1])
  assert_eq(selector_result(selector_plan([":", ":"]), ["a", "b"]).selected, [
    "a", "b",
  ])
  let prefixed = selector_result(
    selector_plan([":", "missing"], prefix="src"),
    ["root", "src/a", "src/b", "src2/a"],
  )
  assert_eq(prefixed.selected, ["src/a", "src/b"])
  assert_eq(prefixed.decisions[1].included_by, [0])
  assert_eq(prefixed.decisions[2].included_by, [0])
  let excluded = selector_result(
    selector_plan([":", "missing", ":!b"], prefix="src"),
    ["root", "src/a", "src/b"],
  )
  assert_eq(excluded.selected, ["src/a"])
  assert_eq(excluded.decisions[2].included_by, [0])
  assert_eq(excluded.decisions[2].excluded_by, [2])
}

///|
test "top patterns preserve dot segments while relative patterns normalize" {
  let paths = ["doc/a", "root"]
  assert_eq(selector_result(selector_plan([":(top)doc/./a"]), paths).selected, [])
  assert_eq(
    selector_result(selector_plan([":(top)doc/../root"]), paths).selected,
    [],
  )
  assert_eq(selector_result(selector_plan(["doc/./a"]), paths).selected, [
    "doc/a",
  ])
  assert_eq(selector_result(selector_plan(["doc/../root"]), paths).selected, [
    "root",
  ])
}

///|
test "nonliteral backslashes fail visibly while literal backslashes match" {
  for pattern in ["a\\b", ":(glob)a\\b", ":(icase)a\\b"] {
    let error = selector_compile_error([pattern])
    assert_eq(error.code, "unsupported_backslash")
    assert_eq(error.pattern_index, Some(0))
  }
  assert_eq(
    selector_result(selector_plan([":(literal)a\\b"]), ["a\\b", "ab"]).selected,
    ["a\\b"],
  )
}

///|
test "glob compilation offsets refer to the original pattern source" {
  let error = selector_compile_error([":(glob)文/["])
  assert_eq(error.code, "invalid_glob")
  assert_eq(error.offset, Some(11))
  let normalized = selector_compile_error([":(glob)./x/../文/["])
  assert_eq(normalized.code, "invalid_glob")
  assert_eq(normalized.offset, Some(18))
}

///|
test "candidate validation is complete and identifies the failing path" {
  let plan = selector_plan(["wanted"])
  for
    bad in [
      "", "/absolute", "a/", "a//b", "./a", "a/./b", "a/../b", "nul\u{0000}x", "C:/outside.txt",
      "c:relative.txt", "\\rooted", "\\\\server\\file",
    ] {
    let error = selector_select_error(plan, ["wanted", bad])
    assert_eq(error.code, "invalid_path")
    assert_eq(error.path_index, Some(1))
  }
  let duplicate = selector_select_error(plan, ["wanted", "unused", "wanted"])
  assert_eq(duplicate.code, "duplicate_path")
  assert_eq(duplicate.path_index, Some(2))
}

///|
test "host-rooted prefixes and pattern bodies are rejected on every backend" {
  for value in ["/root", "C:/root", "d:relative", "\\root", "\\\\server\\file"] {
    assert_eq(selector_compile_error([], prefix=value).code, "invalid_prefix")
    for magic in ["", ":(top)", ":(literal)"] {
      assert_eq(
        selector_compile_error([magic + value]).code,
        "outside_repository",
      )
    }
  }
}

///|
test "configured byte limits count UTF8 rather than UTF16 units" {
  let limits = { ..default_limits(), max_pattern_bytes: 3, max_path_bytes: 3, }
  let plan = selector_plan(["文"], limits~)
  assert_eq(selector_result(plan, ["文"]).selected, ["文"])
  let pattern_error = selector_compile_error(["文a"], limits~)
  assert_eq(pattern_error.code, "pattern_limit")
  assert_eq(pattern_error.pattern_index, Some(0))
  assert_eq(selector_select_error(plan, ["文a"]).code, "path_limit")
  assert_eq(
    selector_compile_error([], prefix="文a", limits~).code,
    "prefix_limit",
  )
}

///|
test "count limits invalid limits and exhausted work fail visibly" {
  assert_eq(
    selector_compile_error(["a", "b"], limits={
      ..default_limits(),
      max_patterns: 1,
    }).code,
    "pattern_limit",
  )
  assert_eq(
    selector_compile_error([], limits={ ..default_limits(), max_paths: 0, }).code,
    "invalid_limits",
  )
  assert_eq(
    selector_compile_error([], limits={
      ..default_limits(),
      max_patterns: 4097,
    }).code,
    "invalid_limits",
  )
  let limited = selector_plan([], limits={ ..default_limits(), max_paths: 1, })
  assert_eq(selector_select_error(limited, ["a", "b"]).code, "path_limit")
  let wildcard = selector_plan(["*"], limits={
    ..default_limits(),
    max_match_steps: 1,
  })
  let match_error = selector_select_error(wildcard, ["a"])
  assert_eq(match_error.code, "match_budget_exceeded")
  assert_eq(match_error.pattern_index, Some(0))
  assert_eq(match_error.path_index, Some(0))
  let aggregate = selector_plan([], limits={
    ..default_limits(),
    max_total_steps: 1,
  })
  assert_eq(selector_select_error(aggregate, ["a"]).code, "work_limit")
}

///|
test "a fixed-work result succeeds at its inclusive aggregate budget" {
  let normal = selector_result(selector_plan(["a"]), ["a"])
  assert_true(normal.steps >= 3)
  let plan = selector_plan(["a"], limits={
    ..default_limits(),
    max_total_steps: normal.steps,
  })
  let result = selector_result(plan, ["a"])
  assert_eq(result.selected, ["a"])
  assert_eq(result.steps, normal.steps)
  let insufficient = selector_plan(["a"], limits={
    ..default_limits(),
    max_total_steps: normal.steps - 1,
  })
  assert_eq(selector_select_error(insufficient, ["a"]).code, "work_limit")
}

///|
test "failed attribute queries also consume selection work" {
  let base = selector_result(selector_plan(["a"]), ["a"])
  let plan = selector_plan([":(attr:checked)a"], limits={
    ..default_limits(),
    max_total_steps: base.steps,
  })
  let error = selector_select_error(plan, ["a"])
  assert_eq(error.code, "work_limit")
  assert_eq(error.path_index, Some(0))
}

///|
test "the aggregate work budget carries across candidate paths" {
  let first = selector_result(selector_plan(["a"]), ["a"])
  let plan = selector_plan(["a"], limits={
    ..default_limits(),
    max_total_steps: first.steps,
  })
  let error = selector_select_error(plan, ["a", "b"])
  assert_eq(error.code, "work_limit")
  assert_eq(error.path_index, Some(1))
}

///|
test "path identity remains case sensitive even under icase selection" {
  let plan = selector_plan([":(icase)a"])
  assert_eq(selector_result(plan, ["A", "a"]).selected, ["A", "a"])
  assert_eq(selector_result(selector_plan([]), []).selected, [])
  match explain(plan, "../a") {
    Ok(_) => abort("expected invalid explanation path")
    Err(error) => {
      assert_eq(error.code, "invalid_path")
      assert_eq(error.path_index, Some(0))
    }
  }
}

///|
test "attribute callbacks cannot replace validated candidate paths" {
  let plan = selector_plan([":(attr:ready)*"])
  for replacement in ["../outside", "a", "overlong".repeat(3000)] {
    let paths = ["a", "b"]
    let result = selector_result(plan, paths, attribute=fn(path, _) {
      if path == "a" {
        paths[1] = replacement
      }
      Set
    })
    assert_eq(result.selected, ["a", "b"])
    assert_eq(result.decisions.map(d => d.path), ["a", "b"])
    assert_eq(paths[1], replacement)
  }
}

///|
test "attribute callbacks cannot append candidates past the original count" {
  let plan = selector_plan([":(attr:ready)*"], limits={
    ..default_limits(),
    max_paths: 2,
  })
  let paths = ["a", "b"]
  let result = selector_result(plan, paths, attribute=fn(path, _) {
    if path == "a" {
      paths.push("c")
    }
    Set
  })
  assert_eq(result.selected, ["a", "b"])
  assert_eq(result.decisions.length(), 2)
  assert_eq(paths, ["a", "b", "c"])
}

///|
test "attribute callbacks cannot truncate the in-flight candidate snapshot" {
  let plan = selector_plan([":(attr:ready)*"])
  let paths = ["a", "b"]
  let result = selector_result(plan, paths, attribute=fn(path, _) {
    if path == "a" {
      paths.clear()
    }
    Set
  })
  assert_eq(result.selected, ["a", "b"])
  assert_eq(result.decisions.map(d => d.path), ["a", "b"])
  assert_eq(paths, [])
}
