///|
fn parser_error(code : String, offset : Int32, message : String) -> ParseError {
  { code, offset, message, }
}

///|
fn parser_text(bytes : Bytes, start : Int32, end : Int32) -> String {
  @utf8.decode_lossy(bytes[start:end])
}

///|
fn parser_alnum(byte : Byte) -> Bool {
  (byte >= b'a' && byte <= b'z') ||
  (byte >= b'A' && byte <= b'Z') ||
  (byte >= b'0' && byte <= b'9')
}

///|
fn parser_name_byte(byte : Byte) -> Bool {
  parser_alnum(byte) || byte == b'_' || byte == b'-' || byte == b'.'
}

///|
fn parser_value_byte(byte : Byte) -> Bool {
  parser_alnum(byte) || byte == b'_' || byte == b'-' || byte == b','
}

///|
fn parser_options_error(options : PathspecOptions) -> ParseError? {
  if !["2.43.0", "2.56.0"].contains(options.git_version) {
    return Some(
      parser_error(
        "invalid_git_version", 0, "git_version must select 2.43.0 or 2.56.0",
      ),
    )
  }
  if options.glob && options.noglob {
    return Some(
      parser_error(
        "conflicting_options", 0, "global glob and noglob settings are incompatible",
      ),
    )
  }
  if options.literal && (options.glob || options.icase) {
    return Some(
      parser_error(
        "conflicting_options", 0, "global literal is incompatible with global glob or icase",
      ),
    )
  }
  None
}

///|
// Git's long-magic scanner skips escaped commas and closing parentheses before
// the attribute-value grammar unescapes and validates the contents separately.
fn parser_magic_end(bytes : Bytes, start : Int32) -> Int32 {
  let mut cursor = start
  while cursor < bytes.length() {
    let byte = bytes[cursor]
    if byte == b'\\' && cursor + 1 < bytes.length() {
      cursor += 2
    } else if byte == b',' || byte == b')' {
      break
    } else {
      cursor += 1
    }
  }
  cursor
}

///|
// Match Git's signed decimal strtol grammar without signed overflow. Negative
// values disable the explicit-prefix override. An empty value means zero.
fn parser_prefix_length(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Result[Int32?, ParseError] {
  if start == end {
    return Ok(Some(0))
  }
  let mut cursor = start
  while cursor < end &&
        (bytes[cursor] == b' ' || (bytes[cursor] >= 9 && bytes[cursor] <= 13)) {
    cursor += 1
  }
  let mut negative = false
  if cursor < end && (bytes[cursor] == b'-' || bytes[cursor] == b'+') {
    negative = bytes[cursor] == b'-'
    cursor += 1
  }
  let digit_start = cursor
  let limit = if negative { -2147483648 } else { -2147483647 }
  let mut accumulated = 0
  while cursor < end {
    let byte = bytes[cursor]
    if byte < b'0' || byte > b'9' {
      return Err(
        parser_error(
          "invalid_prefix_magic", cursor, "prefix requires a signed decimal integer",
        ),
      )
    }
    let digit = byte.to_int() - 48
    if accumulated < limit / 10 {
      return Err(
        parser_error(
          "invalid_prefix_magic", cursor, "prefix exceeds the safe Int32 range",
        ),
      )
    }
    accumulated *= 10
    if accumulated < limit + digit {
      return Err(
        parser_error(
          "invalid_prefix_magic", cursor, "prefix exceeds the safe Int32 range",
        ),
      )
    }
    accumulated -= digit
    cursor += 1
  }
  if cursor == digit_start {
    return Err(
      parser_error(
        "invalid_prefix_magic", start, "prefix requires a signed decimal integer",
      ),
    )
  }
  if negative && accumulated != 0 {
    Ok(None)
  } else {
    Ok(Some(-accumulated))
  }
}

///|
// ASCII punctuation reserved for short magic, excluding glob/regex symbols.
// Git's documented top and exclude signatures are the supported members.
fn parser_signature_byte(byte : Byte) -> Bool {
  match byte {
    b'!'
    | b'"'
    | b'#'
    | b'%'
    | b'&'
    | b'\''
    | b','
    | b'-'
    | b'/'
    | b';'
    | b'<'
    | b'='
    | b'>'
    | b'@'
    | b'_'
    | b'`'
    | b'~'
    | b'^' => true
    _ => false
  }
}

///|
fn parser_attributes(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Result[Array[AttributeCondition], ParseError] {
  if start == end {
    return Err(
      parser_error("invalid_attribute", start, "attr: requires a specification"),
    )
  }
  let conditions : Array[AttributeCondition] = []
  let mut cursor = start
  while cursor < end {
    // Git's pathspec attr list is separated by ASCII spaces, not all whitespace.
    if bytes[cursor] == b' ' {
      cursor = cursor + 1
      continue
    }
    let token_start = cursor
    while cursor < end && bytes[cursor] != b' ' {
      cursor = cursor + 1
    }
    let token_end = cursor
    let prefix = bytes[token_start]
    let name_start = if prefix == b'-' || prefix == b'!' {
      token_start + 1
    } else {
      token_start
    }
    let mut name_end = token_end
    if prefix != b'-' && prefix != b'!' {
      let mut pos = name_start
      while pos < token_end {
        if bytes[pos] == b'=' {
          name_end = pos
          break
        }
        pos = pos + 1
      }
    }
    if name_start == name_end {
      return Err(
        parser_error(
          "invalid_attribute", name_start, "attribute name must not be empty",
        ),
      )
    }
    if bytes[name_start] == b'-' {
      return Err(
        parser_error(
          "invalid_attribute", name_start, "attribute name must not start with '-'",
        ),
      )
    }
    for pos in name_start..<name_end {
      if !parser_name_byte(bytes[pos]) {
        return Err(
          parser_error(
            "invalid_attribute", pos, "invalid attribute name character",
          ),
        )
      }
    }
    let name = parser_text(bytes, name_start, name_end)
    if prefix == b'-' {
      conditions.push(IsUnset(name))
    } else if prefix == b'!' {
      conditions.push(IsUnspecified(name))
    } else if name_end == token_end {
      conditions.push(IsSet(name))
    } else {
      let value_bytes : Array[Byte] = []
      let mut pos = name_end + 1
      while pos < token_end {
        let mut byte = bytes[pos]
        if byte == b'\\' {
          pos = pos + 1
          if pos == token_end {
            return Err(
              parser_error(
                "invalid_attribute",
                pos - 1,
                "attribute value ends with an escape",
              ),
            )
          }
          byte = bytes[pos]
        }
        if !parser_value_byte(byte) {
          return Err(
            parser_error(
              "invalid_attribute", pos, "invalid attribute value character",
            ),
          )
        }
        value_bytes.push(byte)
        pos = pos + 1
      }
      conditions.push(
        Equals(name, @utf8.decode_lossy(Bytes::from_array(value_bytes))),
      )
    }
  }
  Ok(conditions)
}

///|
/// Parse the public Git pathspec magic profile, preserving the pattern body.
/// Error offsets are zero-based UTF-8 byte offsets into `source`. This function
/// does not interpret wildcards, normalize paths, or read attribute files.
/// The bare `:` sentinel is represented by `no_pathspec`; the selector treats
/// it as a positive selection of the current prefix, including in a mixed list.
///
/// Specification: https://git-scm.com/docs/gitglossary#def_pathspec
pub fn parse_pattern(source : String) -> Result[ParsedPattern, ParseError] {
  parse_pattern_options(source, default_pathspec_options())
}

///|
fn parse_pattern_options(
  source : String,
  options : PathspecOptions,
) -> Result[ParsedPattern, ParseError] {
  if parser_options_error(options) is Some(error) {
    return Err(error)
  }
  let bytes = @utf8.encode(source)
  let length = bytes.length()
  if length == 0 {
    return Err(parser_error("empty_pattern", 0, "pathspec must not be empty"))
  }
  for pos in 0..<length {
    if bytes[pos] == 0 {
      return Err(parser_error("nul_byte", pos, "pathspec must not contain NUL"))
    }
  }
  let mut top = false
  let mut literal = false
  let mut glob = false
  let mut icase = false
  let mut exclude = false
  let mut attributes : Array[AttributeCondition] = []
  let mut prefix_length : Int32? = None
  let mut body_start = 0
  let no_pathspec = !options.literal && length == 1 && bytes[0] == b':'
  if bytes[0] == b':' && !options.literal {
    body_start = 1
    if length > 1 && bytes[1] == b'(' {
      let mut closing = parser_magic_end(bytes, 2)
      while closing < length && bytes[closing] != b')' {
        closing = parser_magic_end(bytes, closing + 1)
      }
      if closing == length {
        return Err(
          parser_error("unclosed_magic", 1, "pathspec magic is missing ')'"),
        )
      }
      let mut token_start = 2
      let mut seen_attr = false
      while token_start < closing {
        let token_end = parser_magic_end(bytes, token_start)
        let word = parser_text(bytes, token_start, token_end)
        match word {
          "" => ()
          "top" => top = true
          "literal" => {
            if glob {
              return Err(
                parser_error(
                  "conflicting_magic", token_start, "literal and glob cannot be combined",
                ),
              )
            }
            literal = true
          }
          "glob" => {
            if literal {
              return Err(
                parser_error(
                  "conflicting_magic", token_start, "literal and glob cannot be combined",
                ),
              )
            }
            glob = true
          }
          "icase" => icase = true
          "exclude" => exclude = true
          "attr" => ()
          _ =>
            if word.has_prefix("prefix:") {
              match parser_prefix_length(bytes, token_start + 7, token_end) {
                Ok(value) => prefix_length = value
                Err(error) => return Err(error)
              }
            } else if word.has_prefix("attr:") {
              if seen_attr {
                return Err(
                  parser_error(
                    "invalid_attribute", token_start, "only one attr: specification is allowed",
                  ),
                )
              }
              seen_attr = true
              match parser_attributes(bytes, token_start + 5, token_end) {
                Err(error) => return Err(error)
                Ok(conditions) => attributes = conditions
              }
            } else {
              return Err(
                parser_error(
                  "unknown_magic", token_start, "unsupported pathspec magic",
                ),
              )
            }
        }
        token_start = token_end + 1
      }
      body_start = closing + 1
    } else {
      while body_start < length {
        let byte = bytes[body_start]
        if byte == b':' {
          body_start = body_start + 1
          break
        }
        if !parser_signature_byte(byte) {
          break
        }
        match byte {
          b'/' => top = true
          b'!' | b'^' => exclude = true
          _ =>
            return Err(
              parser_error(
                "unknown_magic", body_start, "unsupported short pathspec magic",
              ),
            )
        }
        body_start = body_start + 1
      }
    }
  }
  let local_literal = literal
  literal = literal || options.literal || (options.noglob && !glob)
  glob = glob || (options.glob && !local_literal)
  icase = icase || options.icase
  Ok({
    original: source,
    pattern: parser_text(bytes, body_start, length),
    magic: { top, literal, glob, icase, exclude, attributes, },
    no_pathspec,
    prefix_length,
  })
}
