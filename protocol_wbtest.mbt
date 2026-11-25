///|
fn protocol_result(source : String) -> Json raise {
  let output = dispatch(source)
  @json.parse(output[:])
}

///|
fn protocol_field(value : Json, name : String) -> Json {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => abort("missing JSON field: " + name)
      }
    _ => abort("expected JSON object")
  }
}

///|
fn protocol_error(source : String, code : String) -> Json raise {
  let result = protocol_result(source)
  assert_eq(protocol_field(result, "schema_version"), Json(1))
  assert_eq(protocol_field(result, "exit_code"), Json(2))
  let error = protocol_field(result, "error")
  assert_eq(protocol_field(error, "code"), Json(code))
  assert_eq(protocol_field(error, "offset_unit"), Json("utf8_byte"))
  error
}

///|
test "protocol global pathspec options expose merged state and prefix magic" {
  let result = protocol_result(
    "{\"command\":\"inspect\",\"patterns\":[\":(prefix:4,icase)src/A\"],\"options\":{\"glob\":true},\"environment\":{\"GIT_ICASE_PATHSPECS\":\"yes\"}}",
  )
  assert_eq(protocol_field(result, "exit_code"), Json(0))
  let options = protocol_field(result, "options")
  assert_eq(protocol_field(options, "glob"), Json(true))
  assert_eq(protocol_field(options, "icase"), Json(true))
  assert_eq(protocol_field(options, "windows"), Json(false))
  match protocol_field(result, "patterns") {
    Array(items) =>
      assert_eq(protocol_field(items[0], "prefix_length"), Json(4))
    _ => abort("expected inspected patterns")
  }
}

///|
test "protocol options and environment reject unknown keys and wrong types" {
  for
    extra in [
      "\"options\":null", "\"options\":[]", "\"options\":{\"glob\":1}", "\"options\":{\"typo\":false}",
      "\"environment\":[]", "\"environment\":{\"GIT_GLOB_PATHSPECS\":true}", "\"environment\":{\"OTHER\":\"1\"}",
      "\"environment\":{\"GIT_GLOB_PATHSPECS\":\"maybe\"}",
    ] {
    ignore(
      protocol_error(
        "{\"patterns\":[],\"paths\":[]," + extra + "}",
        "invalid_request",
      ),
    )
  }
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[],\"options\":{\"glob\":true,\"noglob\":true}}",
      "conflicting_options",
    ),
  )
}

///|
test "Git environment Boolean spellings include bounded base-zero integers" {
  // Independently measured against Git 2.56.0.windows.4's pathspec settings.
  for value in ["", "FALSE", "no", "Off", "0", "-0", "0x0", "00", "0k"] {
    assert_eq(ps_environment_bool(value, windows=true), Ok(false))
  }
  for
    value in [
      "TRUE", "yes", "On", "1", "2", "-1", "0x10", "010", "1M", "-2g", "2147483647",
      "-2147483648", " 1",
    ] {
    assert_eq(ps_environment_bool(value, windows=true), Ok(true))
  }
  for
    value in [
      "maybe", " true", "true ", "1 ", "08", "0x", "0b1", "1kb", "2g", "2147483648",
      "-2147483649", " ",
    ] {
    assert_true(ps_environment_bool(value, windows=true) is Err(_))
  }
}

///|
test "explicit options override raw environment values before Boolean parsing" {
  let options = ps_pathspec_options(
    Some({ "glob": Json(false), "literal": Json(true) }),
    Some({
      "GIT_GLOB_PATHSPECS": Json("invalid"),
      "GIT_ICASE_PATHSPECS": Json("0"),
    }),
  ).unwrap()
  assert_true(options.literal)
  assert_false(options.glob)
  assert_false(options.icase)
  let result = protocol_result(
    "{\"patterns\":[\"*.txt\"],\"paths\":[\"a.txt\",\"sub/b.txt\"],\"options\":{\"glob\":false},\"environment\":{\"GIT_GLOB_PATHSPECS\":\"yes\"}}",
  )
  assert_eq(protocol_field(result, "selected"), Json(["a.txt", "sub/b.txt"]))
}

///|
test "protocol default select produces a versioned complete response" {
  let result = protocol_result(
    "{\"patterns\":[\"src\",\":!src/tmp\"],\"paths\":[\"README\",\"src/a\",\"src/tmp/b\"]}",
  )
  assert_eq(protocol_field(result, "schema_version"), Json(1))
  assert_eq(protocol_field(result, "exit_code"), Json(0))
  assert_eq(protocol_field(result, "selected"), Json(["src/a"]))
  match protocol_field(result, "decisions") {
    Array(items) => {
      assert_eq(items.length(), 3)
      assert_eq(protocol_field(items[2], "selected"), Json(false))
      assert_eq(protocol_field(items[2], "excluded_by"), Json([1]))
    }
    _ => abort("expected decisions array")
  }
}

///|
test "protocol inspect does not need paths and exposes explicit magic" {
  let result = protocol_result(
    "{\"command\":\"inspect\",\"prefix\":\"src/./sub/..\",\"patterns\":[\":(top,literal)root[1]\",\":(attr:ready)file\"]}",
  )
  assert_eq(protocol_field(result, "exit_code"), Json(0))
  assert_eq(protocol_field(result, "prefix"), Json("src"))
  match protocol_field(result, "patterns") {
    Array(items) => {
      assert_eq(items.length(), 2)
      assert_eq(protocol_field(items[0], "top"), Json(true))
      assert_eq(protocol_field(items[0], "literal"), Json(true))
      assert_eq(protocol_field(items[0], "anchor"), Json(""))
      assert_eq(protocol_field(items[1], "anchor"), Json("src"))
      assert_eq(protocol_field(items[1], "attribute_conditions"), Json(1))
    }
    _ => abort("expected inspect array")
  }
}

///|
test "protocol explain returns path decisions" {
  let result = protocol_result(
    "{\"command\":\"explain\",\"patterns\":[\"x\"],\"paths\":[\"x\",\"y\"]}",
  )
  assert_eq(protocol_field(result, "selected"), Json(["x"]))
  match protocol_field(result, "decisions") {
    Array(items) => {
      assert_eq(protocol_field(items[0], "included_by"), Json([0]))
      assert_eq(protocol_field(items[1], "reason"), Json("no_positive_match"))
    }
    _ => abort("expected decisions array")
  }
}

///|
test "protocol attribute JSON states map to four distinct conditions" {
  let result = protocol_result(
    "{\"batch\":[{\"patterns\":[\":(attr:state)*\"],\"paths\":[\"s\",\"u\",\"v\",\"m\"],\"attributes\":{\"s\":{\"state\":true},\"u\":{\"state\":false},\"v\":{\"state\":\"yes\"},\"m\":{\"state\":null}}},{\"patterns\":[\":(attr:-state)*\"],\"paths\":[\"s\",\"u\"],\"attributes\":{\"s\":{\"state\":true},\"u\":{\"state\":false}}},{\"patterns\":[\":(attr:state=yes)*\"],\"paths\":[\"v\"],\"attributes\":{\"v\":{\"state\":\"yes\"}}},{\"patterns\":[\":(attr:!state)*\"],\"paths\":[\"m\",\"absent\"],\"attributes\":{\"m\":{\"state\":null}}}]}",
  )
  match protocol_field(result, "results") {
    Array(items) => {
      assert_eq(items.length(), 4)
      assert_eq(protocol_field(items[0], "selected"), Json(["s"]))
      assert_eq(protocol_field(items[1], "selected"), Json(["u"]))
      assert_eq(protocol_field(items[2], "selected"), Json(["v"]))
      assert_eq(protocol_field(items[3], "selected"), Json(["m", "absent"]))
    }
    _ => abort("expected batch results")
  }
}

///|
test "protocol batch isolates request errors and rejects unknown envelope fields" {
  let result = protocol_result(
    "{\"batch\":[{\"patterns\":[],\"paths\":[\"a\"]},{\"patterns\":[\":(bad)x\"],\"paths\":[\"a\"]},{\"patterns\":[\"b\"],\"paths\":[\"b\"]}]}",
  )
  match protocol_field(result, "results") {
    Array(items) => {
      assert_eq(protocol_field(items[0], "selected"), Json(["a"]))
      assert_eq(
        protocol_field(protocol_field(items[1], "error"), "code"),
        Json("unknown_magic"),
      )
      assert_eq(protocol_field(items[2], "selected"), Json(["b"]))
    }
    _ => abort("expected batch results")
  }
  ignore(protocol_error("{\"batch\":[],\"unknown\":true}", "invalid_request"))
  ignore(protocol_error("{\"batch\":{}}", "invalid_request"))
}

///|
test "protocol rejects wrong shapes unknown keys and unsupported commands" {
  for
    input in [
      "null", "[]", "{}", "{\"patterns\":null,\"paths\":[]}", "{\"patterns\":[1],\"paths\":[]}",
      "{\"patterns\":[],\"paths\":[false]}", "{\"patterns\":[],\"paths\":[],\"prefix\":1}",
      "{\"patterns\":[],\"paths\":[],\"command\":false}", "{\"patterns\":[],\"paths\":[],\"command\":\"delete\"}",
      "{\"patterns\":[],\"paths\":[],\"unknown\":0}", "{\"patterns\":[],\"paths\":[],\"limits\":{\"unknown\":1}}",
      "{\"patterns\":[],\"paths\":[],\"attributes\":[]}", "{\"patterns\":[],\"paths\":[],\"attributes\":{\"a\":true}}",
      "{\"patterns\":[],\"paths\":[],\"attributes\":{\"a\":{\"x\":1}}}", "{\"patterns\":[],\"paths\":[],\"attributes\":{\"../a\":{}}}",
    ] {
    ignore(protocol_error(input, "invalid_request"))
  }
}

///|
test "protocol rejects noninteger limits without truncation" {
  for value in ["1.5", "-1", "true", "null", "\"10\"", "1e100"] {
    ignore(
      protocol_error(
        "{\"patterns\":[],\"paths\":[],\"limits\":{\"max_paths\":" +
        value +
        "}}",
        "invalid_request",
      ),
    )
  }
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[],\"limits\":{\"max_paths\":0}}", "invalid_limits",
    ),
  )
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[],\"limits\":{\"max_patterns\":4097}}", "invalid_limits",
    ),
  )
  let integer = protocol_result(
    "{\"patterns\":[],\"paths\":[\"a\"],\"limits\":{\"max_paths\":1.0}}",
  )
  assert_eq(protocol_field(integer, "exit_code"), Json(0))
}

///|
test "protocol errors identify the source pattern and candidate index" {
  let magic = protocol_error(
    "{\"patterns\":[\"a\",\":(attr:a=值)x\"],\"paths\":[]}", "invalid_attribute",
  )
  assert_eq(protocol_field(magic, "pattern_index"), Json(1))
  assert_eq(protocol_field(magic, "path_index"), Json::null())
  assert_eq(protocol_field(magic, "offset"), Json(9))
  let duplicate = protocol_error(
    "{\"patterns\":[],\"paths\":[\"a\",\"b\",\"a\"]}", "duplicate_path",
  )
  assert_eq(protocol_field(duplicate, "path_index"), Json(2))
  let nul = protocol_error(
    "{\"patterns\":[\"文\\u0000x\"],\"paths\":[]}", "nul_byte",
  )
  assert_eq(protocol_field(nul, "offset"), Json(3))
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[\"a\\u0000b\"]}", "invalid_path",
    ),
  )
}

///|
test "protocol syntax rejects malformed JSON and unpaired surrogate escapes" {
  for
    input in [
      "", "{", "{\"patterns\":[],}", "{\"patterns\":[\"\\x00\"],\"paths\":[]}", "{\"patterns\":[\"\\ud800\"],\"paths\":[]}",
      "{\"patterns\":[\"\\udc00\"],\"paths\":[]}", "{\"patterns\":[\"\\ud800x\"],\"paths\":[]}",
    ] {
    ignore(protocol_error(input, "invalid_json"))
  }
  let emoji = protocol_result(
    "{\"patterns\":[\"\\ud83d\\ude80\"],\"paths\":[\"🚀\"]}",
  )
  assert_eq(protocol_field(emoji, "selected"), Json(["🚀"]))
}

///|
test "protocol depth budget ignores brackets inside JSON strings" {
  let too_deep = "[".repeat(65) + "0" + "]".repeat(65)
  ignore(protocol_error(too_deep, "input_limit"))
  let within_depth = "[".repeat(64) + "0" + "]".repeat(64)
  ignore(protocol_error(within_depth, "invalid_request"))
  let pattern = "[".repeat(80)
  let request : Json = {
    "patterns": Json([":(literal)" + pattern]),
    "paths": Json([pattern]),
  }
  let result = protocol_result(request.stringify())
  assert_eq(protocol_field(result, "selected"), Json([pattern]))
}

///|
test "protocol batch and selection resource limits are explicit errors" {
  let batch = "{\"batch\":[" + Array::make(257, "{}").join(",") + "]}"
  ignore(protocol_error(batch, "batch_limit"))
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[\"a\",\"b\"],\"limits\":{\"max_paths\":1}}", "path_limit",
    ),
  )
  ignore(
    protocol_error(
      "{\"patterns\":[\"*\"],\"paths\":[\"a\"],\"limits\":{\"max_match_steps\":1}}",
      "match_budget_exceeded",
    ),
  )
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[\"a\"],\"limits\":{\"max_total_steps\":1}}", "work_limit",
    ),
  )
}

///|
test "protocol batch permits its count boundary and stops on exhausted work" {
  let request = "{\"patterns\":[],\"paths\":[]}"
  let batch = protocol_result(
    "{\"batch\":[" + Array::make(256, request).join(",") + "]}",
  )
  match protocol_field(batch, "results") {
    Array(items) => assert_eq(items.length(), 256)
    _ => abort("expected batch results")
  }
  let exhausted = protocol_result(
    "{\"batch\":[{\"patterns\":[],\"paths\":[\"a\"]},{\"patterns\":[\"*\"],\"paths\":[\"b\"],\"limits\":{\"max_match_steps\":1}}]}",
  )
  assert_eq(protocol_field(exhausted, "exit_code"), Json(2))
  assert_eq(
    protocol_field(protocol_field(exhausted, "error"), "code"),
    Json("batch_work_limit"),
  )
  match exhausted {
    Object(fields) => assert_false(fields.contains("results"))
    _ => abort("expected error envelope")
  }
}

///|
test "protocol input byte ceiling fails before JSON parsing" {
  ignore(protocol_error(" ".repeat(16777217), "input_limit"))
}

///|
test "protocol numeric environment distinguishes Linux and Windows references" {
  let request : Json = {
    "patterns": Json([":(top)A.TXT"]),
    "paths": Json(["a.txt"]),
    "environment": { "GIT_ICASE_PATHSPECS": Json("0b1") },
  }
  assert_eq(
    protocol_field(protocol_result(request.stringify()), "selected"),
    Json(["a.txt"]),
  )
  let windows : Json = {
    "patterns": Json([":(top)A.TXT"]),
    "paths": Json(["a.txt"]),
    "options": { "windows": Json(true) },
    "environment": { "GIT_ICASE_PATHSPECS": Json("0b1") },
  }
  ignore(protocol_error(windows.stringify(), "invalid_request"))
  assert_eq(ps_environment_bool("-0b10"), Ok(true))
  assert_eq(ps_environment_bool("0B0"), Ok(false))
  assert_true(ps_environment_bool("0b2") is Err(_))
}

///|
test "protocol selected Git version preserves signed environment boundary" {
  for raw in ["-2147483648", "-2g"] {
    let modern : Json = {
      "patterns": Json(["A"]),
      "paths": Json(["a"]),
      "options": { "git_version": Json("2.56.0") },
      "environment": { "GIT_ICASE_PATHSPECS": Json(raw) },
    }
    assert_eq(
      protocol_field(protocol_result(modern.stringify()), "selected"),
      Json(["a"]),
    )
    let legacy : Json = {
      "patterns": Json(["A"]),
      "paths": Json(["a"]),
      "options": { "git_version": Json("2.43.0") },
      "environment": { "GIT_ICASE_PATHSPECS": Json(raw) },
    }
    ignore(protocol_error(legacy.stringify(), "invalid_request"))
  }
  assert_eq(ps_environment_bool("-2147483647", git_version="2.43.0"), Ok(true))
  ignore(
    protocol_error(
      "{\"patterns\":[],\"paths\":[],\"options\":{\"git_version\":\"unknown\"}}",
      "invalid_request",
    ),
  )
}
