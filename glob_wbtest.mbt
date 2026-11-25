///|
/// Expectations follow gitglossary pathspec rules and Git t3070/t6130 fixtures.
fn glob_test_match(
  pattern : String,
  text : String,
  pathname : Bool,
  icase : Bool,
) -> Bool {
  match compile_glob(pattern, pathname) {
    Err(error) => abort("compile: " + error.message)
    Ok(program) =>
      match run_glob(program, text, icase, 100000) {
        Ok(result) => result.matched
        Err(error) => abort("match: " + error.message)
      }
  }
}

///|
test "glob: compact character sets retain every byte and charge before allocation" {
  let bytes = Bytes::from_array(Array::makei(255, i => (i + 1).to_byte())[:])
  for n = 1; n < 256; n = n + 1 {
    let mask = FixedArray::make(8, 0U)
    glob_class_add(mask, n)
    for j = 1; j < 256; j = j + 1 {
      assert_eq(glob_class_has(mask, bytes[j - 1].to_int()), n == j)
    }
  }
  let program = compile_glob("[a]", false, state_budget=17).unwrap()
  assert_eq(program.states, 17)
  match program.tokens[0] {
    Class(mask, case_mask, _) => {
      assert_eq(mask.length(), 8)
      assert_eq(case_mask.length(), 8)
    }
    _ => fail("expected a compiled byte class")
  }
  match compile_glob("[a]", false, state_budget=16) {
    Err(error) => assert_eq(error.code, "compile_limit")
    Ok(_) => fail("class allocated past state budget")
  }
}

///|
test "glob: default wildcards cross slash and pathname wildcards do not" {
  assert_true(glob_test_match("doc/*.jpg", "doc/sub/b.jpg", false, false))
  assert_false(glob_test_match("doc/*.jpg", "doc/sub/b.jpg", true, false))
  assert_true(glob_test_match("doc/*.jpg", "doc/a.jpg", true, false))
  assert_true(glob_test_match("a?b", "a/b", false, false))
  assert_false(glob_test_match("a?b", "a/b", true, false))
  assert_true(glob_test_match("a[/]b", "a/b", false, false))
  assert_false(glob_test_match("a[/]b", "a/b", true, false))
}

///|
test "glob: recursive components include zero and multiple directories" {
  for path in ["file", "a/file", "a/b/file"] {
    assert_true(glob_test_match("**/file", path, true, false))
  }
  for path in ["a/b", "a/x/b", "a/x/y/b"] {
    assert_true(glob_test_match("a/**/b", path, true, false))
  }
  assert_false(glob_test_match("a/**/b", "a/xb", true, false))
  assert_true(glob_test_match("a/**", "a/x/y", true, false))
  assert_false(glob_test_match("a/**", "a", true, false))
  assert_true(glob_test_match("**", "a/x/y", true, false))
  assert_true(glob_test_match("**", "", true, false))
  assert_false(glob_test_match("**/file", "file", false, false))
}

///|
test "glob: byte wildcards and ASCII case folding" {
  assert_false(glob_test_match("?", "é", true, false))
  assert_true(glob_test_match("??", "é", true, false))
  assert_true(glob_test_match("文件?.txt", "文件a.txt", true, false))
  assert_true(glob_test_match("README.[A-Z]", "readme.x", true, true))
  assert_false(glob_test_match("README.[A-Z]", "readme.x", true, false))
  assert_false(glob_test_match("[!A-Z]", "x", true, true))
  assert_true(glob_test_match("[!A-Z]", "9", true, true))
  assert_false(glob_test_match("É", "é", true, true))
  assert_false(glob_test_match("[A]", "A", true, true))
  assert_false(glob_test_match("[A]", "a", true, true))
  assert_true(glob_test_match("[a]", "A", true, true))
  assert_true(glob_test_match("[Z-a]", "A", true, true))
  assert_true(glob_test_match("[Z-a]", "z", true, true))
  assert_true(glob_test_match("[Z-a]", "_", true, true))
}

///|
test "glob: POSIX byte classes, inversion, literal brackets and escapes" {
  assert_true(glob_test_match("[[:digit:]][[:alpha:]]", "7Z", true, false))
  assert_true(glob_test_match("[[:upper:]]", "z", true, true))
  assert_false(glob_test_match("[[:upper:]]", "z", true, false))
  assert_true(glob_test_match("[[:blank:]]", "\t", true, false))
  assert_true(glob_test_match("[[:space:]]", "\n", true, false))
  assert_true(glob_test_match("[[:punct:]]", "!", true, false))
  assert_false(glob_test_match("[[:alpha:]]", "é", true, false))
  assert_true(glob_test_match("[]a]", "]", true, false))
  assert_true(glob_test_match("[-a]", "-", true, false))
  assert_true(glob_test_match("[a-]", "-", true, false))
  assert_true(glob_test_match("file\\?.txt", "file?.txt", true, false))
  assert_true(glob_test_match("\\[abc\\]", "[abc]", true, false))
  assert_true(glob_test_match("[\\]]", "]", true, false))
  assert_true(glob_test_match("[[:digit:]-a]", "-", true, false))
  assert_true(glob_test_match("[[:digit:]-a]", "7", true, false))
}

///|
test "glob: escaped text remains a wildcard program rather than a literal directory" {
  assert_eq(compile_glob("目录/\\[x\\]", true).unwrap().literal_text, None)
  assert_true(glob_test_match("目录/\\[x\\]", "目录/[x]", true, false))
  assert_false(
    glob_test_match("目录/\\[x\\]", "目录/[x]/child", true, false),
  )
  assert_eq(
    compile_glob("目录/x", true).unwrap().literal_text,
    Some("目录/x"),
  )
}

///|
test "glob: non-component double stars remain ordinary pathname stars" {
  assert_true(glob_test_match("dir/a**", "dir/ab.txt", true, false))
  assert_false(glob_test_match("dir/a**", "dir/a/b.txt", true, false))
  // Independently observed with Git 2.43.0.windows.1 by tests/git_oracle.py.
  assert_true(glob_test_match("a/**b", "a/xb", true, false))
  assert_false(glob_test_match("a/**b", "a/x/b", true, false))
  assert_true(glob_test_match("a/***/b", "a/b", true, false))
  assert_true(glob_test_match("a/***/b", "a/z/deep/b", true, false))
  assert_true(glob_test_match("***/x", "x", true, false))
  assert_true(glob_test_match("***/x", "a/z/x", true, false))
  assert_false(glob_test_match("a/***/b", "a/b", false, false))
}

///|
test "glob: escapes after stars and byte-class compatibility" {
  assert_true(glob_test_match("é*\\a", "éba", true, false))
  assert_true(glob_test_match("[z-a]", "z", true, false))
  assert_false(glob_test_match("[z-a]", "a", true, false))
  assert_true(glob_test_match("[[.a.]]", "a]", true, false))
  assert_true(glob_test_match("[[=a=]]", "a]", true, false))
  assert_false(glob_test_match("\\A", "A", true, true))
  assert_true(glob_test_match("\\a", "A", true, true))
  assert_true(glob_test_match("a/**\\/b", "a/x/y/b", true, false))
  assert_false(glob_test_match("a/**\\/b", "a/b", true, false))
  match compile_glob("é[abc", true) {
    Err(error) => assert_eq(error.offset, 2)
    Ok(_) => fail("unterminated class accepted by internal compiler")
  }
  for pattern in ["[[:unknown:]]", "a\\"] {
    assert_true(compile_glob(pattern, true) is Err(_))
  }
}

///|
test "glob: full-string matching includes empty patterns and paths" {
  assert_true(glob_test_match("", "", true, false))
  assert_false(glob_test_match("", "a", true, false))
  assert_true(glob_test_match("*", "", true, false))
  assert_false(glob_test_match("?", "", true, false))
  assert_false(glob_test_match("a", "ab", true, false))
  assert_false(glob_test_match("a", "a/b", true, false))
}

///|
test "glob: bounded DP fails visibly and has reproducible work accounting" {
  let program = match compile_glob("*a*a*a*a*a*b", false) {
    Ok(program) => program
    Err(_) => abort("compile")
  }
  match run_glob(program, "aaaaaaaaaaaaaaaaaaaaaaaa", false, 10) {
    Err(error) => assert_eq(error.code, "match_budget_exceeded")
    Ok(_) => fail("budget exhaustion must not be a negative match")
  }
  match run_glob(program, "aaaaaaaaaaaaaaaaaaaaaaaa", false, 100000) {
    Ok(result) => {
      assert_false(result.matched)
      assert_eq(result.steps, 1 + program.tokens.length() * 25)
    }
    Err(_) => fail("adequate budget rejected")
  }
  match run_glob(program, "", false, -1) {
    Err(error) => assert_eq(error.code, "invalid_budget")
    Ok(_) => fail("negative budget accepted")
  }
}

///|
test "glob: hard byte limits and NUL fail before matching" {
  match compile_glob("é".repeat(32769), false) {
    Err(error) => {
      assert_eq(error.code, "pattern_too_large")
      assert_eq(error.offset, 65536)
    }
    Ok(_) => fail("oversized pattern accepted")
  }
  let program = match compile_glob("*", false) {
    Ok(program) => program
    Err(_) => abort("compile")
  }
  match run_glob(program, "a".repeat(262145), false, 1000000) {
    Err(error) => assert_eq(error.code, "path_too_large")
    Ok(_) => fail("oversized path accepted")
  }
  match compile_glob("é\u0000", false) {
    Err(error) => {
      assert_eq(error.code, "invalid_nul")
      assert_eq(error.offset, 2)
    }
    Ok(_) => fail("NUL in pattern accepted")
  }
  match run_glob(program, "x\u0000", false, 100) {
    Err(error) => {
      assert_eq(error.code, "invalid_nul")
      assert_eq(error.offset, 1)
    }
    Ok(_) => fail("NUL in text accepted")
  }
  match run_glob(program, "", false, 0) {
    Err(error) => assert_eq(error.code, "match_budget_exceeded")
    Ok(_) => fail("zero budget accepted")
  }
  match run_glob(program, "a", false, 3) {
    Ok(result) => {
      assert_true(result.matched)
      assert_eq(result.steps, 3)
    }
    Err(_) => fail("exact budget rejected")
  }
}
