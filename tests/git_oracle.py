#!/usr/bin/env python3
"""Compare MoonPathspec with an independently created, uncommitted Git index.

Requires Python 3.9+, Git, and (unless --oracle-only) Node. No third-party packages.
The expected selection always comes from git ls-files, never the implementation.
The fixture's attributes are read back with git check-attr for EVERY candidate.
The selected platform controls the core's explicit Windows path normalization.
Reports cover this indexed UTF-8 fixture, not every Git command or filename type.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEED = 20261123
DEFAULT_GENERATED = 260


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def run(command, *, cwd, env, data=None, timeout=60):
    return subprocess.run(command, cwd=cwd, env=env, input=data,
                          capture_output=True, timeout=timeout)


def clean_env(empty_config):
    env = dict(os.environ)
    for name in list(env):
        if name in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                    "GIT_PREFIX", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_ATTR_SOURCE",
                    "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS",
                    "GIT_ICASE_PATHSPECS"} or name.startswith("GIT_CONFIG_KEY_") or name.startswith("GIT_CONFIG_VALUE_"):
            env.pop(name, None)
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(empty_config),
                "GIT_ATTR_NOSYSTEM": "1", "LC_ALL": "C", "LANG": "C"})
    return env


class GitOracle:
    def __init__(self, git, directory, fixture):
        self.git = git
        self.root = Path(directory) / "repo"
        self.root.mkdir()
        empty = Path(directory) / "empty-global-config"
        empty.write_bytes(b"")
        self.env = clean_env(empty)
        self.paths = fixture["paths"]
        self.names = fixture["attribute_names"]
        self.command_count = 0
        self.checked(["init", "-q"])
        self.checked(["config", "core.ignoreCase", "false"])
        self.checked(["config", "core.autocrlf", "false"])
        self.checked(["config", "core.attributesFile", str(empty)])
        for relative in self.paths:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"MoonPathspec independent oracle fixture\n")
        with (self.root / ".gitattributes").open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(fixture["gitattributes"])
        # Deliberately do not add .gitattributes: the candidate index is exactly paths.
        self.checked(["add", "--", *self.paths])
        indexed = self.checked(["ls-files", "-z"]).stdout.decode("utf-8").split("\0")[:-1]
        if set(indexed) != set(self.paths) or len(indexed) != len(self.paths):
            raise RuntimeError("Git index differs from the candidate fixture")
        payload = ("\0".join(self.paths) + "\0").encode("utf-8")
        raw = self.checked(["check-attr", "-z", *self.names, "--stdin"], data=payload).stdout
        fields = raw.decode("utf-8").split("\0")[:-1]
        if len(fields) != len(self.paths) * len(self.names) * 3:
            raise RuntimeError("git check-attr did not return every candidate/name pair")
        self.attributes = {path: {} for path in self.paths}
        for offset in range(0, len(fields), 3):
            path, name, value = fields[offset:offset + 3]
            if path not in self.attributes or name not in self.names or name in self.attributes[path]:
                raise RuntimeError("Unexpected or duplicate git check-attr result")
            self.attributes[path][name] = {"set": True, "unset": False, "unspecified": None}.get(value, value)
        if any(set(values) != set(self.names) for values in self.attributes.values()):
            raise RuntimeError("An attribute candidate/name pair was omitted")

    def execute(self, arguments, *, prefix="", data=None):
        self.command_count += 1
        cwd = self.root / prefix
        if not cwd.is_dir():
            raise RuntimeError("Oracle prefix must name an existing fixture directory: " + prefix)
        return run([self.git, *arguments], cwd=cwd, env=self.env, data=data)

    def checked(self, arguments, *, data=None):
        result = self.execute(arguments, data=data)
        if result.returncode:
            raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
        return result

    def request(self, case, platform):
        return {"patterns": case["patterns"], "paths": self.paths,
                "prefix": case.get("prefix", ""), "attributes": self.attributes,
                "options": {"windows": platform == "windows"}}

    def expected(self, case):
        result = self.execute(["ls-files", "--full-name", "-z", "--", *case["patterns"]],
                              prefix=case.get("prefix", ""))
        if result.returncode:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            # Keep result hashes stable across independently created temporary repositories.
            stderr = stderr.replace(self.root.as_posix(), "<repo>").replace(str(self.root), "<repo>")
            return {"exit_code": 2, "git_exit_code": result.returncode,
                    "selected": [], "stderr": stderr}
        found = result.stdout.decode("utf-8").split("\0")[:-1]
        if len(found) != len(set(found)) or not set(found) <= set(self.paths):
            raise RuntimeError("Git returned duplicates or a path outside the fixture")
        found = set(found)
        return {"exit_code": 0, "git_exit_code": 0,
                "selected": [path for path in self.paths if path in found]}


def generated_cases(fixture, seed, count):
    """Generate syntax, not expected answers. Every answer is obtained from Git."""
    rng = random.Random(seed)
    prefixes = ["", "", "src", "src/lib", "docs", "unicode", "a"]
    bodies = ["*", "*.txt", "*.mbt", "*.md", "?", "[a-z]*", "[!a-z]*", "**/foo",
              "**/*.txt", "**/*.mbt", "**/*.md", "**/x", "***/x", "**", "***", "foo",
              "a/**b", "a/***/b", "a***b", "src/*", "src/**", "src/**/util.mbt",
              "src/lib", "docs", "docs/", "docs/[a-z]*", "docs/*.txt", "docs/?.md",
              "assets/*", "unicode/*", "unicode/???.txt", "unicode/????.txt",
              "unicode/[[:alpha:]]*", "space dir/*", ".hidden", "*.TXT", "SRC/*.MBT",
              "readme.MD", "docs/\\[draft\\].txt", "missing/*", "vendor/**", "."]
    magics = ["", "glob", "icase", "glob,icase", "literal", "top", "top,glob",
              "attr:flag", "attr:-flag", "attr:!flag", "attr:kind=text", "attr:kind=source",
              "attr:review -flag", "attr:!missing", "attr:tag=utf8", "glob,attr:flag"]
    for number in range(count):
        prefix = rng.choice(prefixes)
        patterns = []
        for index in range(rng.randint(1, 4)):
            body = rng.choice(bodies)
            magic = rng.choice(magics)
            # Prefix escapes are lexical and remain inside the repository.
            if prefix and rng.randrange(7) == 0 and "top" not in magic.split(","):
                body = "../" * len(prefix.split("/")) + body
            if index > 0 and rng.randrange(2) == 0 or index == 0 and rng.randrange(8) == 0:
                magic = "exclude" + ("," + magic if magic else "")
            patterns.append(":(" + magic + ")" + body if magic else body)
        case = {"id": "generated-%04d" % number, "category": "seeded-mixture",
                "prefix": prefix, "patterns": patterns}
        yield case


def reference_platform(requested, git_version):
    """Do not label native Windows Git results as POSIX reference evidence."""
    detected = "windows" if os.name == "nt" or ".windows." in git_version.lower() else "posix"
    if requested != "auto" and requested != detected:
        raise ValueError("--platform %s conflicts with the native %s Git reference; "
                         "run the requested platform's Git on that platform" % (requested, detected))
    return detected


def check_response(actual, expected, paths):
    issues = []
    if not isinstance(actual, dict):
        return ["response is not an object"]
    if actual.get("schema_version") != 1:
        issues.append("schema_version must be 1")
    if actual.get("exit_code") != expected["exit_code"]:
        issues.append("exit_code differs")
    if actual.get("selected") != expected["selected"]:
        issues.append("selected differs (fixture/input order is required)")
    if expected["exit_code"] == 2:
        error = actual.get("error")
        if not isinstance(error, dict) or not isinstance(error.get("code"), str) or not error["code"]:
            issues.append("error requires a nonempty code")
        return issues
    if "error" in actual and actual["error"] is not None:
        issues.append("successful response contains an error")
    decisions = actual.get("decisions")
    if not isinstance(decisions, list) or len(decisions) != len(paths):
        issues.append("decisions must cover every input candidate")
    else:
        selected = set(expected["selected"])
        for index, (decision, path) in enumerate(zip(decisions, paths)):
            if not isinstance(decision, dict) or decision.get("path") != path or decision.get("selected") is not (path in selected):
                issues.append("decision %d path/selected differs" % index)
                break
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git", default=shutil.which("git"), help="Git executable")
    parser.add_argument("--node", default=shutil.which("node"), help="Node executable")
    parser.add_argument("--platform", choices=["auto", "posix", "windows"], default="auto",
                        help="Native reference platform; auto detects host/Windows Git version")
    parser.add_argument("--runner", type=Path, default=ROOT / "scripts" / "request.mjs")
    parser.add_argument("--fixture", type=Path, default=ROOT / "tests" / "oracle_cases.json")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "local" / "git-oracle.json")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--generated", type=int, default=DEFAULT_GENERATED)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--oracle-only", action="store_true", help="Capture Git results without claiming implementation verification")
    args = parser.parse_args()
    if not args.git or (not args.node and not args.oracle_only):
        parser.error("Git and, for differential verification, Node must be available")
    if args.generated < 200:
        parser.error("--generated must be at least 200")
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")
    started = time.time()
    fixture_bytes = args.fixture.read_bytes()
    fixture = json.loads(fixture_bytes.decode("utf-8"))
    cases = fixture["cases"] + list(generated_cases(fixture, args.seed, args.generated))
    if any("expected_profile_rejection" in case for case in cases):
        raise RuntimeError("Profile rejection markers are obsolete: every case must compare with Git")
    if len(set(case["id"] for case in cases)) != len(cases):
        raise RuntimeError("Duplicate oracle case ids")
    with tempfile.TemporaryDirectory(prefix="moonpathspec-oracle-") as directory:
        oracle = GitOracle(args.git, directory, fixture)
        git_version = oracle.checked(["--version"]).stdout.decode("utf-8").strip()
        try:
            platform = reference_platform(args.platform, git_version)
        except ValueError as error:
            parser.error(str(error))
        git_build_options = oracle.checked(["version", "--build-options"]).stdout.decode("utf-8").splitlines()
        expected = [oracle.expected(case) for case in cases]
        requests = [oracle.request(case, platform) for case in cases]
        actual = None
        runner_error = None
        node_version = None
        if not args.oracle_only:
            version = run([args.node, "--version"], cwd=ROOT, env=oracle.env)
            node_version = version.stdout.decode("utf-8").strip()
            try:
                actual = []
                for start in range(0, len(requests), args.batch_size):
                    batch = requests[start:start + args.batch_size]
                    process = run([args.node, str(args.runner)], cwd=ROOT, env=oracle.env,
                                  data=json.dumps({"batch": batch}, ensure_ascii=False).encode("utf-8"), timeout=180)
                    if process.returncode:
                        runner_error = {"batch_start": start, "exit_code": process.returncode,
                                        "stderr": process.stderr.decode("utf-8", errors="replace"),
                                        "stdout": process.stdout.decode("utf-8", errors="replace")}
                        actual = None
                        break
                    envelope = json.loads(process.stdout.decode("utf-8"))
                    responses = envelope.get("results") if isinstance(envelope, dict) else None
                    if not isinstance(responses, list) or len(responses) != len(batch):
                        runner_error = {"batch_start": start,
                                        "message": "batch response must contain results with exactly one response per request",
                                        "response": envelope}
                        actual = None
                        break
                    actual.extend(responses)
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                runner_error = {"message": str(error)}
        records = []
        failures = []
        differential_passes = 0
        for index, (case, answer) in enumerate(zip(cases, expected)):
            record = {"id": case["id"], "category": case.get("category", "fixed"),
                      "prefix": case.get("prefix", ""), "patterns": case["patterns"], "expected": answer}
            record["check_kind"] = "git-error" if answer["exit_code"] else "git-selection"
            if actual is not None:
                issues = check_response(actual[index], answer, fixture["paths"])
                record.update({"passed": not issues, "actual": actual[index]})
                if not issues:
                    differential_passes += 1
                if issues:
                    record["issues"] = issues
                    # A complete failing request is retained, including all four-state attributes.
                    failures.append({"id": case["id"], "request": requests[index],
                                     "expected": answer,
                                     "actual": actual[index], "issues": issues})
            records.append(record)
        states = collections.Counter("set" if value is True else "unset" if value is False else
                                     "unspecified" if value is None else "value"
                                     for mapping in oracle.attributes.values() for value in mapping.values())
        report = {"schema_version": 1, "kind": "independent-git-differential",
                  "status": "oracle-only" if args.oracle_only else "failed" if runner_error or failures else "passed",
                  "profile": fixture["profile"], "git_version": git_version, "node_version": node_version,
                  "git_build_options": git_build_options,
                  "git_executable": shutil.which(args.git) or args.git,
                  "platform": platform, "requested_platform": args.platform, "host_platform": sys.platform,
                  "core_options": {"windows": platform == "windows"},
                  "validation_scope": "Recorded UTF-8 indexed candidate paths, working-tree attributes, "
                                      "and git ls-files pathspec selection on the reported native platform; "
                                      "not all Git commands or arbitrary non-UTF-8 filenames",
                  "seed": args.seed, "fixed_cases": len(fixture["cases"]), "generated_cases": args.generated,
                  "batch_size": args.batch_size,
                  "total_cases": len(cases), "candidate_paths": len(fixture["paths"]),
                  "success_cases": sum(answer["exit_code"] == 0 for answer in expected),
                  "error_cases": sum(answer["exit_code"] == 2 for answer in expected),
                  "differential_cases": len(cases),
                  "differential_passed_cases": differential_passes,
                  "git_syntax_or_prefix_error_cases": sum(answer["exit_code"] == 2 for answer in expected),
                  "resource_limit_checks": 0,
                  "compared_cases": len(cases) if actual is not None else 0,
                  "passed_cases": len(cases) - len(failures) if actual is not None else 0,
                  "failed_cases": len(failures), "attribute_pairs": len(fixture["paths"]) * len(fixture["attribute_names"]),
                  "attribute_state_counts": dict(states), "git_commands": oracle.command_count,
                  "fixture_sha256": hashlib.sha256(fixture_bytes).hexdigest(),
                  "generated_cases_sha256": digest(cases[len(fixture["cases"]):]),
                  "candidate_paths_sha256": digest(fixture["paths"]), "attributes_sha256": digest(oracle.attributes),
                  "oracle_results_sha256": digest(expected), "elapsed_seconds": round(time.time() - started, 3),
                  "paths": fixture["paths"], "attributes": oracle.attributes,
                  "failures": failures, "cases": records}
        if runner_error:
            report["runner_error"] = runner_error
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ["status", "total_cases", "compared_cases", "passed_cases", "failed_cases",
                                                 "differential_cases", "differential_passed_cases", "platform",
                                                 "git_version", "fixture_sha256"]}))
    print(str(args.output.resolve()))
    if failures:
        for failure in failures[:12]:
            print(failure["id"] + ": " + "; ".join(failure["issues"]))
    return 0 if report["status"] in {"passed", "oracle-only"} else 1


if __name__ == "__main__":
    sys.exit(main())
