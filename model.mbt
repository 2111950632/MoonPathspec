///|
#derive(Eq, @debug.Debug)
pub(all) enum AttributeValue {
  Set
  Unset
  Unspecified
  Value(String)
}

///|
#derive(Eq, @debug.Debug)
pub(all) enum AttributeCondition {
  IsSet(String)
  IsUnset(String)
  IsUnspecified(String)
  Equals(String, String)
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct ParseError {
  code : String
  offset : Int32
  message : String
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct MagicFlags {
  top : Bool
  literal : Bool
  glob : Bool
  icase : Bool
  exclude : Bool
  attributes : Array[AttributeCondition]
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct ParsedPattern {
  original : String
  pattern : String
  magic : MagicFlags
  no_pathspec : Bool
  prefix_length : Int32?
}

///|
/// Explicit equivalents of Git's global pathspec settings. The library does not
/// read process environment variables. `windows` selects path preprocessing in
/// the caller-facing compiler; magic grammar itself is platform-independent.
#derive(Eq, @debug.Debug)
pub(all) struct PathspecOptions {
  literal : Bool
  glob : Bool
  noglob : Bool
  icase : Bool
  windows : Bool
}

///|
pub fn default_pathspec_options() -> PathspecOptions {
  { literal: false, glob: false, noglob: false, icase: false, windows: false, }
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct Limits {
  max_patterns : Int32
  max_pattern_bytes : Int32
  max_path_bytes : Int32
  max_paths : Int32
  max_match_steps : Int32
  max_total_steps : Int32
}

///|
pub fn default_limits() -> Limits {
  {
    max_patterns: 256,
    max_pattern_bytes: 4096,
    max_path_bytes: 16384,
    max_paths: 100000,
    max_match_steps: 2000000,
    max_total_steps: 20000000,
  }
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct SelectionError {
  code : String
  pattern_index : Int32?
  path_index : Int32?
  offset : Int32?
  message : String
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct Decision {
  path : String
  selected : Bool
  included_by : Array[Int32]
  excluded_by : Array[Int32]
  reason : String
  steps : Int32
}

///|
#derive(Eq, @debug.Debug)
pub(all) struct Selection {
  selected : Array[String]
  decisions : Array[Decision]
  steps : Int32
}
