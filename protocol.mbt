///|
fn ps_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn ps_integer(value : Json) -> Int32? {
  match value {
    Number(n, ..) =>
      if n >= 0.0 && n <= 200000000.0 {
        let i = n.to_int()
        if i.to_double() == n {
          Some(i)
        } else {
          None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn ps_strings(value : Json?) -> Result[Array[String], String] {
  match value {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(text) => out.push(text)
          _ => return Err("expected an array of strings")
        }
      }
      Ok(out)
    }
    _ => Err("expected an array of strings")
  }
}

///|
fn ps_limits(value : Json?) -> Result[Limits, String] {
  let d = default_limits()
  let map = match value {
    None => return Ok(d)
    Some(Object(map)) => map
    _ => return Err("limits must be an object")
  }
  let allowed = [
    "max_patterns", "max_pattern_bytes", "max_path_bytes", "max_paths", "max_match_steps",
    "max_total_steps",
  ]
  for name, raw in map {
    if !allowed.contains(name) {
      return Err("unknown limit: " + name)
    }
    if ps_integer(raw) is None {
      return Err("limits require nonnegative integers within hard ceilings")
    }
  }
  fn get(name : String, fallback : Int32) -> Int32 {
    map.get(name).bind(ps_integer).unwrap_or(fallback)
  }
  Ok({
    max_patterns: get("max_patterns", d.max_patterns),
    max_pattern_bytes: get("max_pattern_bytes", d.max_pattern_bytes),
    max_path_bytes: get("max_path_bytes", d.max_path_bytes),
    max_paths: get("max_paths", d.max_paths),
    max_match_steps: get("max_match_steps", d.max_match_steps),
    max_total_steps: get("max_total_steps", d.max_total_steps),
  })
}

///|
// Git v2.56 parse.c accepts case-insensitive boolean words, the empty string,
// or an Int32 parsed with base 0 and an optional k/m/g (1024) suffix.
fn ps_environment_bool(text : String) -> Result[Bool, String] {
  match ps_ascii_fold(text) {
    "" | "false" | "no" | "off" => return Ok(false)
    "true" | "yes" | "on" => return Ok(true)
    _ => ()
  }
  let bytes = @utf8.encode(text)
  let mut end = bytes.length()
  let mut power = 0
  if end > 0 {
    match bytes[end - 1] {
      b'k' | b'K' => power = 1
      b'm' | b'M' => power = 2
      b'g' | b'G' => power = 3
      _ => ()
    }
    if power != 0 {
      end -= 1
    }
  }
  let mut cursor = 0
  while cursor < end &&
        (bytes[cursor] == b' ' || (bytes[cursor] >= 9 && bytes[cursor] <= 13)) {
    cursor += 1
  }
  let mut negative = false
  if cursor < end && (bytes[cursor] == b'+' || bytes[cursor] == b'-') {
    negative = bytes[cursor] == b'-'
    cursor += 1
  }
  let mut base = 10
  if cursor < end && bytes[cursor] == b'0' {
    base = 8
    if cursor + 1 < end &&
      (bytes[cursor + 1] == b'x' || bytes[cursor + 1] == b'X') {
      base = 16
      cursor += 2
    }
  }
  let digit_start = cursor
  let limit = if negative { -2147483648 } else { -2147483647 }
  let mut value = 0
  while cursor < end {
    let byte = bytes[cursor]
    let digit = if byte >= b'0' && byte <= b'9' {
      byte.to_int() - 48
    } else if byte >= b'a' && byte <= b'f' {
      byte.to_int() - 87
    } else if byte >= b'A' && byte <= b'F' {
      byte.to_int() - 55
    } else {
      return Err("invalid Git boolean environment value")
    }
    if digit >= base || value < limit / base {
      return Err("invalid or overflowing Git boolean environment integer")
    }
    value *= base
    if value < limit + digit {
      return Err("overflowing Git boolean environment integer")
    }
    value -= digit
    cursor += 1
  }
  if digit_start == end {
    return Err("invalid Git boolean environment value")
  }
  for _ in 0..<power {
    if value < limit / 1024 {
      return Err("overflowing Git boolean environment integer")
    }
    value *= 1024
  }
  Ok(value != 0)
}

///|
fn ps_pathspec_options(
  value : Json?,
  environment : Json?,
) -> Result[PathspecOptions, String] {
  let fields = match value {
    None => Map([])
    Some(Object(fields)) => fields
    _ => return Err("options must be an object")
  }
  let combined : Map[String, Bool] = Map([])
  for name, raw in fields {
    if !["literal", "glob", "noglob", "icase", "windows"].contains(name) {
      return Err("unknown pathspec option: " + name)
    }
    match raw {
      True => combined.set(name, true)
      False => combined.set(name, false)
      _ => return Err("pathspec options require Boolean values")
    }
  }
  let variables = match environment {
    None => Map([])
    Some(Object(fields)) => fields
    _ => return Err("environment must be an object")
  }
  for name, raw in variables {
    let option = match name {
      "GIT_LITERAL_PATHSPECS" => "literal"
      "GIT_GLOB_PATHSPECS" => "glob"
      "GIT_NOGLOB_PATHSPECS" => "noglob"
      "GIT_ICASE_PATHSPECS" => "icase"
      _ => return Err("unknown pathspec environment variable: " + name)
    }
    let text = match raw {
      String(text) => text
      _ => return Err("pathspec environment values must be raw strings")
    }
    if !combined.contains(option) {
      match ps_environment_bool(text) {
        Ok(value) => combined.set(option, value)
        Err(message) => return Err(name + ": " + message)
      }
    }
  }
  Ok({
    literal: combined.get("literal").unwrap_or(false),
    glob: combined.get("glob").unwrap_or(false),
    noglob: combined.get("noglob").unwrap_or(false),
    icase: combined.get("icase").unwrap_or(false),
    windows: combined.get("windows").unwrap_or(false),
  })
}

///|
fn ps_read_attributes(
  value : Json?,
) -> Result[Map[String, Map[String, AttributeValue]], String] {
  let out : Map[String, Map[String, AttributeValue]] = Map([])
  let fields = match value {
    None => return Ok(out)
    Some(Object(fields)) => fields
    _ => return Err("attributes must be an object keyed by candidate path")
  }
  for path, raw in fields {
    if !ps_canonical_path(path) {
      return Err("attribute path is not canonical")
    }
    let attrs = match raw {
      Object(attrs) => attrs
      _ => return Err("each attribute record must be an object")
    }
    let converted : Map[String, AttributeValue] = Map([])
    for name, raw in attrs {
      let state = match raw {
        True => AttributeValue::Set
        False => AttributeValue::Unset
        Null => AttributeValue::Unspecified
        String(text) => AttributeValue::Value(text)
        _ =>
          return Err("attribute values must be true, false, null or a string")
      }
      converted.set(name, state)
    }
    out.set(path, converted)
  }
  Ok(out)
}

///|
fn ps_error_json(error : SelectionError) -> Json {
  {
    "schema_version": Json(1),
    "exit_code": Json(2),
    "selected": Json::array([]),
    "error": {
      "code": Json(error.code),
      "message": Json(error.message),
      "pattern_index": match error.pattern_index {
        Some(n) => Json(n)
        None => Json::null()
      },
      "path_index": match error.path_index {
        Some(n) => Json(n)
        None => Json::null()
      },
      "offset": match error.offset {
        Some(n) => Json(n)
        None => Json::null()
      },
      "offset_unit": Json("utf8_byte"),
    },
  }
}

///|
pub fn decision_json(decision : Decision) -> Json {
  {
    "path": Json(decision.path),
    "selected": Json(decision.selected),
    "included_by": Json(decision.included_by),
    "excluded_by": Json(decision.excluded_by),
    "reason": Json(decision.reason),
    "steps": Json(decision.steps),
  }
}

///|
pub fn selection_json(selection : Selection) -> Json {
  {
    "schema_version": Json(1),
    "exit_code": Json(0),
    "selected": Json(selection.selected),
    "decisions": Json(selection.decisions.map(decision_json)),
    "steps": Json(selection.steps),
  }
}

///|
fn ps_request(request : Json, work_ceiling~ : Int32 = 200000000) -> Json {
  fn bad(message : String) -> Json {
    ps_error_json(selection_error("invalid_request", message))
  }
  let fields = match request {
    Object(fields) => fields
    _ => return bad("request must be an object")
  }
  for name, _ in fields {
    if ![
        "patterns", "paths", "prefix", "attributes", "limits", "command", "options",
        "environment",
      ].contains(name) {
      return bad("unknown request field: " + name)
    }
  }
  let patterns = match ps_strings(ps_field(request, "patterns")) {
    Ok(v) => v
    Err(message) => return bad("patterns: " + message)
  }
  let prefix = match ps_field(request, "prefix") {
    None => ""
    Some(String(v)) => v
    _ => return bad("prefix must be a string")
  }
  let command = match ps_field(request, "command") {
    None => "select"
    Some(String(v)) => v
    _ => return bad("command must be a string")
  }
  if !["select", "explain", "inspect"].contains(command) {
    return bad("unknown command")
  }
  let configured = match ps_limits(ps_field(request, "limits")) {
    Ok(v) => v
    Err(message) => return bad(message)
  }
  let options = match
    ps_pathspec_options(
      ps_field(request, "options"),
      ps_field(request, "environment"),
    ) {
    Ok(value) => value
    Err(message) => return bad(message)
  }
  let limits = if configured.max_total_steps > work_ceiling {
    {
      max_patterns: configured.max_patterns,
      max_pattern_bytes: configured.max_pattern_bytes,
      max_path_bytes: configured.max_path_bytes,
      max_paths: configured.max_paths,
      max_match_steps: configured.max_match_steps,
      max_total_steps: work_ceiling,
    }
  } else {
    configured
  }
  let plan = match compile(patterns, prefix~, limits~, options~) {
    Ok(v) => v
    Err(error) => return ps_error_json(error)
  }
  if command == "inspect" {
    return {
      "schema_version": Json(1),
      "exit_code": Json(0),
      "prefix": Json(plan.prefix),
      "options": {
        "literal": Json(options.literal),
        "glob": Json(options.glob),
        "noglob": Json(options.noglob),
        "icase": Json(options.icase),
        "windows": Json(options.windows),
      },
      "patterns": Json(
        plan.clauses.map(clause => {
          "original": Json(clause.source.original),
          "anchor": Json(clause.anchor),
          "pattern": Json(clause.source.pattern),
          "top": Json(clause.source.magic.top),
          "literal": Json(clause.source.magic.literal),
          "glob": Json(clause.source.magic.glob),
          "icase": Json(clause.source.magic.icase),
          "exclude": Json(clause.source.magic.exclude),
          "prefix_length": match clause.source.prefix_length {
            Some(value) => Json(value)
            None => Json::null()
          },
          "attribute_conditions": Json(clause.source.magic.attributes.length()),
        }),
      ),
    }
  }
  let paths = match ps_strings(ps_field(request, "paths")) {
    Ok(v) => v
    Err(message) => return bad("paths: " + message)
  }
  let attrs = match ps_read_attributes(ps_field(request, "attributes")) {
    Ok(v) => v
    Err(message) => return bad(message)
  }
  let attribute = fn(path, name) {
    attrs
    .get(path)
    .bind(row => row.get(name))
    .unwrap_or(AttributeValue::Unspecified)
  }
  match select(plan, paths, attribute~) {
    Ok(value) => selection_json(value)
    Err(error) => ps_error_json(error)
  }
}

///|
/// Host bridge. Syntax, validation and matching remain in MoonBit.
pub fn dispatch(source : String) -> String {
  if @utf8.encode(source).length() > 16777216 {
    return ps_error_json(
      selection_error("input_limit", "request exceeds 16 MiB"),
    ).stringify()
  }
  let chars = source.to_array()
  let mut depth = 0
  let mut quoted = false
  let mut escaped = false
  for c in chars {
    if quoted {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
    } else if c == '"' {
      quoted = true
    } else if c == '{' || c == '[' {
      depth += 1
      if depth > 64 {
        return ps_error_json(
          selection_error("input_limit", "JSON nesting exceeds 64"),
        ).stringify()
      }
    } else if c == '}' || c == ']' {
      depth -= 1
    }
  }
  let request = @json.parse(source[:]) catch {
    error =>
      return ps_error_json(selection_error("invalid_json", error.to_string())).stringify()
  }
  match ps_field(request, "batch") {
    Some(Array(batch)) => {
      let fields = match request {
        Object(fields) => fields
        _ => abort("unreachable")
      }
      if fields.length() != 1 {
        return ps_error_json(
          selection_error(
            "invalid_request", "batch envelope accepts only the batch field",
          ),
        ).stringify()
      }
      if batch.length() > 256 {
        return ps_error_json(
          selection_error("batch_limit", "batch exceeds 256 requests"),
        ).stringify()
      }
      let results : Array[Json] = []
      let mut spent = 0
      for item in batch {
        if spent >= 200000000 {
          return ps_error_json(
            selection_error(
              "batch_work_limit", "aggregate batch work budget exhausted",
            ),
          ).stringify()
        }
        let result = ps_request(item, work_ceiling=200000000 - spent)
        let code = ps_field(result, "error").bind(error => {
          ps_field(error, "code")
        })
        if code == Some(Json("work_limit")) ||
          code == Some(Json("match_budget_exceeded")) {
          return ps_error_json(
            selection_error(
              "batch_work_limit", "a request exhausted its budget; batch stopped without partial results",
            ),
          ).stringify()
        }
        spent += ps_field(result, "steps").bind(ps_integer).unwrap_or(0)
        results.push(result)
      }
      let response : Json = {
        "schema_version": Json(1),
        "results": Json(results),
      }
      response.stringify()
    }
    Some(_) =>
      ps_error_json(
        selection_error("invalid_request", "batch must be an array"),
      ).stringify()
    None => ps_request(request).stringify()
  }
}
