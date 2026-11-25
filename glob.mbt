///|
/// A compiled, byte-oriented wildcard program. No host regular expression engine
/// is used. Directory selection and pathspec magic are handled by the selector.
priv struct GlobProgram {
  tokens : Array[GlobToken]
  pathname : Bool
  literal_text : String?
  states : Int32
}

///|
priv struct GlobMatch {
  matched : Bool
  steps : Int32
}

///|
priv enum GlobToken {
  Never
  Literal(Int32)
  Escaped(Int32)
  Any
  Star(Bool)
  Directories
  Class(FixedArray[UInt32], FixedArray[UInt32], Bool)
}

///|
fn glob_error(code : String, offset : Int32, message : String) -> ParseError {
  { code, offset, message, }
}

///|
/// The limits here protect callers of the internal matcher too. The public
/// selector applies its usually much smaller configurable limits first.
fn compile_glob(
  pattern : String,
  pathname : Bool,
  state_budget~ : Int32 = 65536,
  protected_prefix~ : Int32 = 0,
) -> Result[GlobProgram, ParseError] {
  let bytes = @utf8.encode(pattern[:])
  if bytes.length() > 65536 {
    return Err(
      glob_error(
        "pattern_too_large", 65536, "Glob exceeds the internal 65536-byte limit.",
      ),
    )
  }
  let tokens : Array[GlobToken] = []
  let literals : Array[Byte] = []
  let mut all_literal = true
  let mut states = 0
  let mut i = 0
  while i < bytes.length() {
    let b = bytes[i].to_int()
    // A class owns two eight-word bitsets, plus its token. Charge before any
    // allocation so a small input cannot expand into an unbounded plan.
    let cost = if b == 91 && i >= protected_prefix { 17 } else { 1 }
    if cost > state_budget - states {
      return Err(
        glob_error("compile_limit", i, "Compiled pattern state limit exceeded."),
      )
    }
    states += cost
    if b == 0 {
      return Err(
        glob_error("invalid_nul", i, "NUL is not a valid Git path byte."),
      )
    }
    if i < protected_prefix {
      tokens.push(Literal(b))
      literals.push(bytes[i])
      i += 1
    } else if b == 92 {
      all_literal = false
      if i + 1 == bytes.length() {
        return Err(
          glob_error(
            "invalid_glob", i, "A trailing backslash has no byte to escape.",
          ),
        )
      }
      let escaped = bytes[i + 1].to_int()
      if escaped == 0 {
        return Err(
          glob_error("invalid_nul", i + 1, "NUL is not a valid Git path byte."),
        )
      }
      tokens.push(Escaped(escaped))
      literals.push(bytes[i + 1])
      i += 2
    } else if b == 42 {
      all_literal = false
      let start = i
      while i < bytes.length() && bytes[i].to_int() == 42 {
        i += 1
      }
      let count = i - start
      let left_boundary = start == 0 || bytes[start - 1].to_int() == 47
      let right_boundary = i == bytes.length() || bytes[i].to_int() == 47
      let escaped_slash = i + 1 < bytes.length() &&
        bytes[i].to_int() == 92 &&
        bytes[i + 1].to_int() == 47
      // The measured Git 2.56 baseline also treats a whole *** component as
      // recursive, despite the narrower syntax described in gitglossary.
      if pathname &&
        count >= 2 &&
        left_boundary &&
        (right_boundary || escaped_slash) {
        if i < bytes.length() && !escaped_slash {
          tokens.push(Directories)
          i += 1 // **/ includes its following slash, including the zero-dir case.
        } else {
          tokens.push(Star(true))
        }
      } else {
        tokens.push(Star(!pathname))
      }
    } else if b == 63 {
      all_literal = false
      tokens.push(Any)
      i += 1
    } else if b == 91 {
      all_literal = false
      match glob_parse_class(bytes, i) {
        Err(error) => return Err(error)
        Ok((token, next)) => {
          tokens.push(token)
          i = next
        }
      }
    } else {
      tokens.push(Literal(b))
      literals.push(bytes[i])
      i += 1
    }
  }
  let literal_text = if all_literal {
    let value = Bytes::from_array(literals[:])
    Some(@utf8.decode_lossy(value[:]))
  } else {
    None
  }
  Ok({ tokens, pathname, literal_text, states, })
}

///|
/// Parse the byte class independently into normal and case-folded masks.
/// The public selector retains invalid wildcard syntax as a non-matching
/// program after checking the original literal path, following Git.
fn glob_parse_class(
  bytes : Bytes,
  start : Int32,
) -> Result[(GlobToken, Int32), ParseError] {
  let mask = FixedArray::make(8, 0U)
  let case_mask = FixedArray::make(8, 0U)
  let mut i = start + 1
  let mut inverted = false
  if i < bytes.length() && (bytes[i] == b'!' || bytes[i] == b'^') {
    inverted = true
    i += 1
  }
  let mut first = true
  let mut previous = 0
  while i < bytes.length() {
    let value = bytes[i].to_int()
    if value == 93 && !first {
      return Ok((Class(mask, case_mask, inverted), i + 1))
    }
    first = false
    if value == 92 {
      if i + 1 >= bytes.length() {
        return Err(
          glob_error(
            "invalid_glob", i, "Unterminated escaped class class_byte.",
          ),
        )
      }
      let class_byte = bytes[i + 1].to_int()
      if class_byte == 0 {
        return Err(glob_error("invalid_nul", i + 1, "NUL is not a path byte."))
      }
      glob_class_add(mask, class_byte)
      glob_class_add(case_mask, class_byte)
      previous = class_byte
      i += 2
    } else if value == 45 &&
      previous != 0 &&
      i + 1 < bytes.length() &&
      bytes[i + 1] != b']' {
      let mut end = i + 1
      if bytes[end] == b'\\' {
        end += 1
      }
      if end >= bytes.length() {
        return Err(
          glob_error("invalid_glob", i, "Unterminated range endpoint."),
        )
      }
      let hi = bytes[end].to_int()
      for class_byte = previous; class_byte <= hi; class_byte = class_byte + 1 {
        glob_class_add(mask, class_byte)
        glob_class_add(case_mask, glob_fold(class_byte))
      }
      previous = 0
      i = end + 1
    } else if value == 91 && i + 1 < bytes.length() && bytes[i + 1] == b':' {
      let mut end = i + 2
      while end < bytes.length() && bytes[end] != b']' {
        end += 1
      }
      if end == bytes.length() {
        return Err(glob_error("invalid_glob", i, "Unterminated POSIX class."))
      }
      if end > i + 2 && bytes[end - 1] == b':' {
        let name = @utf8.decode_lossy(bytes[i + 2:end - 1])
        if ![
            "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print",
            "punct", "space", "upper", "xdigit",
          ].contains(name) {
          return Err(
            glob_error("unsupported_posix_class", i, "Unknown POSIX class."),
          )
        }
        for class_byte = 0; class_byte < 256; class_byte = class_byte + 1 {
          if glob_posix_member(name, class_byte) {
            glob_class_add(mask, class_byte)
            glob_class_add(case_mask, glob_fold(class_byte))
          }
        }
        previous = 0
        i = end + 1
      } else {
        glob_class_add(mask, value)
        glob_class_add(case_mask, value)
        previous = value
        i += 1
      }
    } else {
      if value == 0 {
        return Err(glob_error("invalid_nul", i, "NUL is not a path byte."))
      }
      glob_class_add(mask, value)
      glob_class_add(case_mask, value)
      previous = value
      i += 1
    }
  }
  Err(glob_error("invalid_glob", start, "Unterminated bracket expression."))
}

///|
/// POSIX classes intentionally use the ASCII/C-locale byte definitions.
fn glob_posix_member(name : String, byte : Int32) -> Bool {
  let upper = byte >= 65 && byte <= 90
  let lower = byte >= 97 && byte <= 122
  let digit = byte >= 48 && byte <= 57
  match name {
    "alnum" => upper || lower || digit
    "alpha" => upper || lower
    "blank" => byte == 9 || byte == 32
    "cntrl" => byte < 32 || byte == 127
    "digit" => digit
    "graph" => byte >= 33 && byte <= 126
    "lower" => lower
    "print" => byte >= 32 && byte <= 126
    "punct" => byte >= 33 && byte <= 126 && !(upper || lower || digit)
    "space" => byte == 32 || (byte >= 9 && byte <= 13)
    "upper" => upper
    "xdigit" =>
      digit || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
    _ => false
  }
}

///|
fn glob_fold(byte : Int32) -> Int32 {
  if byte >= 65 && byte <= 90 {
    byte + 32
  } else {
    byte
  }
}

///|
fn glob_class_matches(
  mask : FixedArray[UInt32],
  case_mask : FixedArray[UInt32],
  inverted : Bool,
  byte : Int32,
  icase : Bool,
) -> Bool {
  let is_member = if icase {
    glob_class_has(case_mask, glob_fold(byte))
  } else {
    glob_class_has(mask, byte)
  }
  if inverted {
    !is_member
  } else {
    is_member
  }
}

///|
fn glob_class_add(mask : FixedArray[UInt32], byte : Int32) -> Unit {
  let word = byte / 32
  mask[word] = mask[word] | (1U << (byte % 32))
}

///|
fn glob_class_has(mask : FixedArray[UInt32], byte : Int32) -> Bool {
  (mask[byte / 32] & (1U << (byte % 32))) != 0U
}

///|
/// Each token transforms a row of reachable UTF-8 byte offsets. A star extends
/// its row left-to-right; **/ keeps an active prefix until a slash is reached.
/// This uses O(path bytes) memory and O(tokens * path bytes) bounded work, with
/// no recursive or exponential backtracking. One examined DP cell is one step.
fn run_glob(
  program : GlobProgram,
  text : String,
  icase : Bool,
  budget : Int32,
) -> Result[GlobMatch, ParseError] {
  let bytes = @utf8.encode(text[:])
  let length = bytes.length()
  if length > 262144 {
    return Err(
      glob_error(
        "path_too_large", 262144, "Path exceeds the internal 262144-byte limit.",
      ),
    )
  }
  for i = 0; i < length; i = i + 1 {
    if bytes[i].to_int() == 0 {
      return Err(
        glob_error("invalid_nul", i, "NUL is not a valid Git path byte."),
      )
    }
  }
  if budget < 0 {
    return Err(
      glob_error("invalid_budget", 0, "Match budget must be nonnegative."),
    )
  }
  if budget == 0 {
    return Err(
      glob_error(
        "match_budget_exceeded", 0, "Wildcard matching exhausted its step budget.",
      ),
    )
  }
  let mut steps = 1
  let mut row = Array::make(length + 1, false)
  row[0] = true
  for token in program.tokens {
    let next = Array::make(length + 1, false)
    let mut active = false
    for j = 0; j <= length; j = j + 1 {
      if steps >= budget {
        return Err(
          glob_error(
            "match_budget_exceeded", 0, "Wildcard matching exhausted its step budget.",
          ),
        )
      }
      steps += 1
      match token {
        Never => ()
        Escaped(expected) =>
          if j < length && row[j] {
            let actual = bytes[j].to_int()
            if (if icase { glob_fold(actual) } else { actual }) == expected {
              next[j + 1] = true
            }
          }
        Literal(expected) =>
          if j < length && row[j] {
            let actual = bytes[j].to_int()
            if (if icase {
                glob_fold(expected) == glob_fold(actual)
              } else {
                expected == actual
              }) {
              next[j + 1] = true
            }
          }
        Any =>
          if j < length &&
            row[j] &&
            (!program.pathname || bytes[j].to_int() != 47) {
            next[j + 1] = true
          }
        Star(cross_slash) => {
          if row[j] {
            next[j] = true
          }
          if j < length && next[j] && (cross_slash || bytes[j].to_int() != 47) {
            next[j + 1] = true
          }
        }
        Directories => {
          if row[j] {
            next[j] = true
            active = true
          }
          if j < length && active && bytes[j].to_int() == 47 {
            next[j + 1] = true
          }
        }
        Class(mask, case_mask, inverted) =>
          if j < length && row[j] {
            let actual = bytes[j].to_int()
            if (!program.pathname || actual != 47) &&
              glob_class_matches(mask, case_mask, inverted, actual, icase) {
              next[j + 1] = true
            }
          }
      }
    }
    row = next
  }
  Ok({ matched: row[length], steps, })
}
