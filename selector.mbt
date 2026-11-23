///|
struct CompiledClause {
  index : Int32
  source : ParsedPattern
  anchor : String
  program : GlobProgram
}

///|
/// Opaque compiled selection plan. All patterns are checked before it is returned.
pub struct Plan {
  priv clauses : Array[CompiledClause]
  priv prefix : String
  priv limits : Limits
  priv has_positive : Bool
}

///|
fn selection_error(code : String, message : String) -> SelectionError {
  { code, message, pattern_index: None, path_index: None, offset: None, }
}

///|
fn ps_join(parts : Array[String]) -> String {
  parts.join("/")
}

///|
fn ps_parts(value : String) -> Array[String] {
  value.split("/").map(part => part.to_owned()).to_array()
}

///|
// Keep drive-relative and rooted Windows forms outside this portable profile.
fn ps_host_rooted(value : String) -> Bool {
  if value.has_prefix("/") || value.has_prefix("\\") {
    return true
  }
  value.length() >= 2 &&
  value[1] == ':' &&
  ((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z'))
}

///|
fn ps_valid_limits(limits : Limits) -> Bool {
  limits.max_patterns > 0 &&
  limits.max_patterns <= 4096 &&
  limits.max_pattern_bytes > 0 &&
  limits.max_pattern_bytes <= 65536 &&
  limits.max_path_bytes > 0 &&
  limits.max_path_bytes <= 65536 &&
  limits.max_paths > 0 &&
  limits.max_paths <= 1000000 &&
  limits.max_match_steps > 0 &&
  limits.max_match_steps <= 100000000 &&
  limits.max_total_steps > 0 &&
  limits.max_total_steps <= 200000000
}

///|
fn ps_normalize_prefix(prefix : String) -> Result[String, String] {
  if ps_host_rooted(prefix) || prefix.contains("\u{0000}") {
    return Err("prefix must be a repository-relative path without NUL")
  }
  let out : Array[String] = []
  for part in ps_parts(prefix) {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if out.is_empty() {
        return Err("prefix leaves the repository root")
      }
      out.remove(out.length() - 1) |> ignore
    } else {
      out.push(part)
    }
  }
  Ok(ps_join(out))
}

///|
// Keep the caller's prefix separate: icase must not case-fold that prefix.
fn ps_resolve(
  prefix : String,
  body : String,
) -> Result[(String, String, Array[Int32]), String] {
  if ps_host_rooted(body) {
    return Err("absolute patterns are outside the relative-path profile")
  }
  let parts : Array[String] = if prefix == "" { [] } else { ps_parts(prefix) }
  let positions : Array[Int32] = parts.map(_ => -1)
  let mut fixed = parts.length()
  let mut cursor = 0
  for part in ps_parts(body) {
    let start = cursor
    cursor += @utf8.encode(part).length() + 1
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.is_empty() {
        return Err("pattern leaves the repository root")
      }
      if parts.length() <= fixed {
        fixed -= 1
      }
      parts.remove(parts.length() - 1) |> ignore
      positions.remove(positions.length() - 1) |> ignore
    } else {
      parts.push(part)
      positions.push(start)
    }
  }
  let anchor = ps_join(parts[:fixed].to_owned())
  let mut pattern = ps_join(parts[fixed:].to_owned())
  let offsets : Array[Int32] = []
  for i = fixed; i < parts.length(); i = i + 1 {
    if i > fixed {
      offsets.push(positions[i] - 1)
    }
    for j = 0; j < @utf8.encode(parts[i]).length(); j = j + 1 {
      offsets.push(positions[i] + j)
    }
  }
  if body.has_suffix("/") && pattern != "" {
    pattern += "/"
    offsets.push(@utf8.encode(body).length() - 1)
  }
  offsets.push(@utf8.encode(body).length())
  Ok((anchor, pattern, offsets))
}

///|
pub fn compile(
  patterns : Array[String],
  prefix~ : String = "",
  limits~ : Limits = default_limits(),
) -> Result[Plan, SelectionError] {
  if !ps_valid_limits(limits) {
    return Err(
      selection_error(
        "invalid_limits", "limits must be positive and within the documented hard ceilings",
      ),
    )
  }
  if patterns.length() > limits.max_patterns {
    return Err(selection_error("pattern_limit", "too many patterns"))
  }
  if @utf8.encode(prefix).length() > limits.max_path_bytes {
    return Err(selection_error("prefix_limit", "prefix is too long"))
  }
  let prefix = match ps_normalize_prefix(prefix) {
    Ok(value) => value
    Err(message) => return Err(selection_error("invalid_prefix", message))
  }
  let clauses : Array[CompiledClause] = []
  let mut has_positive = false
  let mut total_bytes = 0
  let mut compiled_states = 0
  for index, text in patterns {
    let size = @utf8.encode(text).length()
    if size > limits.max_pattern_bytes || size > 1048576 - total_bytes {
      return Err({
        code: "pattern_limit",
        message: "pattern bytes exceed the configured or aggregate limit",
        pattern_index: Some(index),
        path_index: None,
        offset: None,
      })
    }
    total_bytes += size
    let parsed = match parse_pattern(text) {
      Ok(value) => value
      Err(error) =>
        return Err({
          code: error.code,
          message: error.message,
          pattern_index: Some(index),
          path_index: None,
          offset: Some(error.offset),
        })
    }
    if ps_host_rooted(parsed.pattern) {
      return Err({
        code: "outside_repository",
        message: "rooted and drive-qualified patterns are outside the relative-path profile",
        pattern_index: Some(index),
        path_index: None,
        offset: None,
      })
    }
    if !parsed.magic.literal && parsed.pattern.contains("\\") {
      return Err({
        code: "unsupported_backslash",
        message: "GPP-1 requires forward-slash patterns; use literal magic for literal metacharacters",
        pattern_index: Some(index),
        path_index: None,
        offset: None,
      })
    }
    let resolved = if parsed.magic.top {
      let offsets : Array[Int32] = []
      let size = @utf8.encode(parsed.pattern).length()
      for i = 0; i <= size; i = i + 1 {
        offsets.push(i)
      }
      Ok(("", parsed.pattern, offsets))
    } else {
      ps_resolve(prefix, parsed.pattern)
    }
    let (anchor, body, offsets) = match resolved {
      Ok(value) => value
      Err(message) =>
        return Err({
          code: "outside_repository",
          message,
          pattern_index: Some(index),
          path_index: None,
          offset: None,
        })
    }
    let compiled_offsets : Array[Int32] = []
    let glob_text = if parsed.magic.literal {
      let mut escaped = ""
      let mut byte_cursor = 0
      for c in body.to_array() {
        if c == '*' || c == '?' || c == '[' || c == '\\' {
          escaped += "\\"
          compiled_offsets.push(offsets[byte_cursor])
        }
        escaped += c.to_string()
        let width = @utf8.encode(c.to_string()).length()
        for j = 0; j < width; j = j + 1 {
          compiled_offsets.push(offsets[byte_cursor + j])
        }
        byte_cursor += width
      }
      compiled_offsets.push(offsets[byte_cursor])
      escaped
    } else {
      for offset in offsets {
        compiled_offsets.push(offset)
      }
      body
    }
    let program = match
      compile_glob(
        glob_text,
        parsed.magic.glob,
        state_budget=65536 - compiled_states,
      ) {
      Ok(value) => value
      Err(error) => {
        let position = if error.offset >= 0 &&
          error.offset < compiled_offsets.length() {
          compiled_offsets[error.offset]
        } else {
          @utf8.encode(parsed.pattern).length()
        }
        return Err({
          code: error.code,
          message: error.message,
          pattern_index: Some(index),
          path_index: None,
          offset: Some(
            @utf8.encode(parsed.original).length() -
            @utf8.encode(parsed.pattern).length() +
            position,
          ),
        })
      }
    }
    compiled_states += program.states
    if !parsed.magic.exclude {
      has_positive = true
    }
    clauses.push({ index, source: parsed, anchor, program, })
  }
  Ok({ clauses, prefix, limits, has_positive, })
}

///|
fn ps_ascii_fold(value : String) -> String {
  String::from_array(
    value
    .to_array()
    .map(c => {
      if c >= 'A' && c <= 'Z' {
        (c.to_int() + 32).unsafe_to_char()
      } else {
        c
      }
    }),
  )
}

///|
fn ps_under(path : String, directory : String) -> Bool {
  directory == "" || path == directory || path.has_prefix(directory + "/")
}

///|
fn ps_attributes(
  conditions : Array[AttributeCondition],
  path : String,
  query : (String, String) -> AttributeValue,
) -> Bool {
  for condition in conditions {
    let success = match condition {
      IsSet(name) => query(path, name) == AttributeValue::Set
      IsUnset(name) => query(path, name) == AttributeValue::Unset
      IsUnspecified(name) => query(path, name) == AttributeValue::Unspecified
      Equals(name, value) => query(path, name) == AttributeValue::Value(value)
    }
    if !success {
      return false
    }
  }
  true
}

///|
fn ps_canonical_path(path : String) -> Bool {
  if path == "" ||
    ps_host_rooted(path) ||
    path.has_suffix("/") ||
    path.contains("\u{0000}") {
    return false
  }
  for part in ps_parts(path) {
    if part == "" || part == "." || part == ".." {
      return false
    }
  }
  true
}

///|
pub fn select(
  plan : Plan,
  paths : Array[String],
  attribute~ : (String, String) -> AttributeValue = fn(_, _) {
    AttributeValue::Unspecified
  },
) -> Result[Selection, SelectionError] {
  if paths.length() > plan.limits.max_paths {
    return Err(selection_error("path_limit", "too many candidate paths"))
  }
  let seen : Map[String, Bool] = Map([])
  for index, path in paths {
    if !ps_canonical_path(path) {
      return Err({
        code: "invalid_path",
        message: "candidate paths must be canonical repository-relative file paths",
        path_index: Some(index),
        pattern_index: None,
        offset: None,
      })
    }
    if @utf8.encode(path).length() > plan.limits.max_path_bytes {
      return Err({
        code: "path_limit",
        message: "candidate path is too long",
        path_index: Some(index),
        pattern_index: None,
        offset: None,
      })
    }
    if seen.contains(path) {
      return Err({
        code: "duplicate_path",
        message: "duplicate candidate path",
        path_index: Some(index),
        pattern_index: None,
        offset: None,
      })
    }
    seen.set(path, true)
  }
  let selected : Array[String] = []
  let decisions : Array[Decision] = []
  let mut total = 0
  for path_index, path in paths {
    let included : Array[Int32] = []
    let excluded : Array[Int32] = []
    let mut steps = @utf8.encode(path).length() + 1
    for clause in plan.clauses {
      let pattern_index = clause.index
      steps += @utf8.encode(clause.anchor).length() + 1
      if total + steps > plan.limits.max_total_steps {
        return Err({
          code: "work_limit",
          message: "selection work budget exhausted",
          path_index: Some(path_index),
          pattern_index: Some(pattern_index),
          offset: None,
        })
      }
      if !ps_under(path, clause.anchor) {
        continue
      }
      let relative = if clause.anchor == "" {
        path
      } else if path == clause.anchor {
        ""
      } else {
        path[clause.anchor.length() + 1:].to_owned()
      }
      let matched = match clause.program.literal_text {
        Some(literal) => {
          steps += @utf8.encode(relative).length() +
            @utf8.encode(literal).length()
          let relative = if clause.source.magic.icase {
            ps_ascii_fold(relative)
          } else {
            relative
          }
          let literal = if clause.source.magic.icase {
            ps_ascii_fold(literal)
          } else {
            literal
          }
          if literal.has_suffix("/") {
            relative.has_prefix(literal)
          } else {
            ps_under(relative, literal)
          }
        }
        None => {
          let remaining = plan.limits.max_total_steps - total - steps
          let budget = if remaining < plan.limits.max_match_steps {
            remaining
          } else {
            plan.limits.max_match_steps
          }
          match
            run_glob(
              clause.program,
              relative,
              clause.source.magic.icase,
              budget,
            ) {
            Ok(value) => {
              steps += value.steps
              value.matched
            }
            Err(error) =>
              return Err({
                code: error.code,
                message: error.message,
                pattern_index: Some(pattern_index),
                path_index: Some(path_index),
                offset: Some(error.offset),
              })
          }
        }
      }
      if matched {
        steps += clause.source.magic.attributes.length()
        if total + steps > plan.limits.max_total_steps {
          return Err({
            code: "work_limit",
            message: "selection work budget exhausted before attribute query",
            path_index: Some(path_index),
            pattern_index: Some(pattern_index),
            offset: None,
          })
        }
        if ps_attributes(clause.source.magic.attributes, path, attribute) {
          if clause.source.magic.exclude {
            excluded.push(pattern_index)
          } else {
            included.push(pattern_index)
          }
        }
      }
    }
    total += steps
    if total > plan.limits.max_total_steps {
      return Err({
        code: "work_limit",
        message: "selection work budget exhausted",
        path_index: Some(path_index),
        pattern_index: None,
        offset: None,
      })
    }
    let implicit = !plan.has_positive && ps_under(path, plan.prefix)
    let is_selected = (implicit || !included.is_empty()) && excluded.is_empty()
    if is_selected {
      selected.push(path)
    }
    let reason = if !excluded.is_empty() {
      "excluded_by_pattern"
    } else if !included.is_empty() {
      "included_by_pattern"
    } else if implicit {
      "implicit_prefix_selection"
    } else {
      "no_positive_match"
    }
    decisions.push({
      path,
      selected: is_selected,
      included_by: included,
      excluded_by: excluded,
      reason,
      steps,
    })
  }
  Ok({ selected, decisions, steps: total, })
}

///|
pub fn explain(
  plan : Plan,
  path : String,
  attribute~ : (String, String) -> AttributeValue = fn(_, _) {
    AttributeValue::Unspecified
  },
) -> Result[Decision, SelectionError] {
  match select(plan, [path], attribute~) {
    Ok(selection) => Ok(selection.decisions[0])
    Err(error) => Err(error)
  }
}
