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
    if !["patterns", "paths", "prefix", "attributes", "limits", "command"].contains(
        name,
      ) {
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
  let plan = match compile(patterns, prefix~, limits~) {
    Ok(v) => v
    Err(error) => return ps_error_json(error)
  }
  if command == "inspect" {
    return {
      "schema_version": Json(1),
      "exit_code": Json(0),
      "prefix": Json(plan.prefix),
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
