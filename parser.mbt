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
  parser_alnum(byte) || byte == b'_' || byte == b'-'
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
  let mut body_start = 0
  let no_pathspec = length == 1 && bytes[0] == b':'
  if bytes[0] == b':' {
    body_start = 1
    if length > 1 && bytes[1] == b'(' {
      let mut closing = 2
      while closing < length && bytes[closing] != b')' {
        closing = closing + 1
      }
      if closing == length {
        return Err(
          parser_error("unclosed_magic", 1, "pathspec magic is missing ')'"),
        )
      }
      let mut token_start = 2
      let mut seen_attr = false
      while token_start < closing {
        let mut token_end = token_start
        while token_end < closing && bytes[token_end] != b',' {
          token_end = token_end + 1
        }
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
            if word.has_prefix("attr:") {
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
  Ok({
    original: source,
    pattern: parser_text(bytes, body_start, length),
    magic: { top, literal, glob, icase, exclude, attributes, },
    no_pathspec,
  })
}
