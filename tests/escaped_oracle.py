#!/usr/bin/env python3
"""Independently compare escaped pathspecs with a real Git virtual index.

No expected answer is computed by the MoonBit implementation. Windows raw
escape checks use top magic; non-top POSIX checks are explicitly not run there.
Literal * and ? names live in the index, not in Windows worktree files.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
import uuid


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "escaped-pathspec"
SEED = 20261125
ATTRIBUTE_NAMES = ["publish", "generated", "kind", "missing"]
ATTRIBUTES = ("docs/** publish -generated kind=text\n"
              "docs/b* generated\n"
              "docs/comma.txt kind=a,b\n"
              "assets/** -publish -generated kind=asset\n"
              "src/** !publish !generated kind=source\n")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def clean_env(empty):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(empty),
                "GIT_ATTR_NOSYSTEM": "1", "LC_ALL": "C", "LANG": "C"})
    return env


class VirtualIndex:
    def __init__(self, directory, git, paths, attributes, platform, reference_version):
        self.root = Path(directory)
        self.root.mkdir(parents=True)
        self.git = git
        self.paths = paths
        self.platform = platform
        self.reference_version = reference_version
        self.commands = 0
        empty = self.root.parent / (self.root.name + "-empty-config")
        empty.write_bytes(b"")
        self.env = clean_env(empty)
        self.checked(["init", "-q"])
        self.checked(["config", "core.ignoreCase", "false"])
        self.checked(["config", "core.protectNTFS", "false"])
        self.checked(["config", "core.autocrlf", "false"])
        self.checked(["config", "core.attributesFile", str(empty)])
        blob = self.checked(["hash-object", "-w", "--stdin"],
                            data=b"MoonPathspec virtual-index fixture\n").stdout.decode().strip()
        payload = b"".join(("100644 " + blob + "\t" + path + "\0").encode("utf-8")
                           for path in paths)
        self.checked(["update-index", "-z", "--index-info"], data=payload)
        indexed = self.checked(["ls-files", "-z"]).stdout.decode("utf-8").split("\0")[:-1]
        if len(indexed) != len(paths) or set(indexed) != set(paths):
            raise RuntimeError("Virtual index differs from supplied candidates")
        # Only safe directory names are created. Funny leaf names remain index-only.
        for relative in ["src", "src/lib", "docs", "docs/nested", "assets", "tools"]:
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        (self.root / ".gitattributes").write_text(attributes, encoding="utf-8")
        fields = self.checked(
            ["check-attr", "-z", *ATTRIBUTE_NAMES, "--stdin"],
            data=("\0".join(paths) + "\0").encode("utf-8")
        ).stdout.decode("utf-8").split("\0")[:-1]
        if len(fields) != len(paths) * len(ATTRIBUTE_NAMES) * 3:
            raise RuntimeError("git check-attr omitted an attribute pair")
        self.attributes = {path: {} for path in paths}
        for path, name, value in zip(fields[::3], fields[1::3], fields[2::3]):
            if path not in self.attributes or name not in ATTRIBUTE_NAMES:
                raise RuntimeError("Unexpected git check-attr field")
            if name in self.attributes[path]:
                raise RuntimeError("Duplicate git check-attr pair")
            self.attributes[path][name] = {
                "set": True, "unset": False, "unspecified": None
            }.get(value, value)
        if any(set(values) != set(ATTRIBUTE_NAMES) for values in self.attributes.values()):
            raise RuntimeError("Incomplete attribute table")

    def execute(self, args, *, prefix="", data=None, environment=None):
        self.commands += 1
        folder = self.root / prefix
        if not folder.is_dir():
            raise RuntimeError("Oracle prefix is not an existing directory: " + prefix)
        # Copy each time: raw boolean values never contaminate the next case.
        env = dict(self.env)
        env.update(environment or {})
        return subprocess.run([self.git, *args], cwd=folder, env=env, input=data,
                              capture_output=True, timeout=30)

    def checked(self, args, *, data=None):
        result = self.execute(args, data=data)
        if result.returncode:
            raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
        return result

    def expected(self, request):
        options = request.get("options", {})
        flags = [flag for name, flag in [
            ("literal", "--literal-pathspecs"), ("glob", "--glob-pathspecs"),
            ("noglob", "--noglob-pathspecs"), ("icase", "--icase-pathspecs")
        ] if options.get(name)]
        if options.get("literal") is False and "literal" in options:
            flags.append("--no-literal-pathspecs")
        env = dict(self.env)
        env.update(request.get("environment", {}))
        for name, variable in [("literal", "GIT_LITERAL_PATHSPECS"), ("glob", "GIT_GLOB_PATHSPECS"),
                               ("noglob", "GIT_NOGLOB_PATHSPECS"), ("icase", "GIT_ICASE_PATHSPECS")]:
            if name in options:
                env[variable] = "1" if options[name] else "0"
        process = self.execute(
            [*flags, "ls-files", "--full-name", "-z", "--", *request["patterns"]],
            prefix=request.get("prefix", ""), environment=env
        )
        if process.returncode:
            return {"exit_code": 2, "git_exit_code": process.returncode, "selected": [],
                    "stderr": process.stderr.decode("utf-8", errors="replace").strip()
                    .replace(str(self.root), "<repo>").replace(self.root.as_posix(), "<repo>")}
        listed = process.stdout.decode("utf-8").split("\0")[:-1]
        if len(listed) != len(set(listed)) or not set(listed) <= set(self.paths):
            raise RuntimeError("Git returned duplicates or foreign candidates")
        selected = set(listed)
        return {"exit_code": 0, "git_exit_code": 0,
                "selected": [path for path in self.paths if path in selected]}

    def request(self, case):
        return {"patterns": case["patterns"], "paths": self.paths,
                "prefix": case.get("prefix", ""), "attributes": self.attributes,
                "options": {"windows": self.platform == "windows", "git_version": self.reference_version, **case.get("options", {})},
                "environment": case.get("environment", {}), "command": "explain"}


def broad_paths(base, platform):
    extra = [
        "docs/axb.txt", "docs/a[b].txt", "docs/ab.txt", "docs/a].txt",
        "docs/a[.txt", "docs/[].txt", "docs/].txt", "docs/-a.txt",
        "docs/filea.txt", "docs/filem.txt", "docs/file-.txt", "docs/file].txt",
        "docs/a^b.txt", "docs/trail", "docs/nested/z[draft].txt", "docs/empty.txt",
        "docs/[[:digit:]].txt", "docs/4.txt", "docs/*.txt", "docs/?.txt",
        "docs/f[.txt", "src/lib/a[draft].txt", "src/lib/foo.txt",
        "src/lib/f[o][o].txt", "src/lib/a?report.txt", "src/lib/a*report.txt",
        "docs/UPPER.TXT", "docs/lower.txt", "docs/sub/inner.txt", "docs/comma.txt",
    ]
    if platform == "posix":
        # These are real POSIX index names. Never feed them to Windows Git.
        extra.extend(["docs/back\\slash.txt", "docs/trail\\",
                      "docs/*\\", "docs/[\\].txt"])
    return list(dict.fromkeys(base + extra))


def fixed_cases(platform):
    cases = []

    def add(name, patterns, *, prefix="", options=None, environment=None, mode="all"):
        cases.append({"id": name, "category": "boundary", "patterns": patterns,
                      "prefix": prefix, "options": options or {},
                      "environment": environment or {}, "mode": mode})

    # Default and glob forms exercise escaping before and after active wildcards,
    # malformed classes, exact-identity fallback, byte ranges, and recursion.
    bodies = [
        r"docs/\[draft\].txt", r"docs/*\[draft\].txt",
        r"docs/*\?report.txt", r"docs/*\*report.txt",
        r"docs/a\?report.txt", r"docs/a\*report.txt",
        r"docs/\a[draft].txt", r"docs/[[]draft].txt",
        r"docs/a[[]b].txt", r"docs/[[]*.txt",
        "docs/a[broken", "docs/no[", "docs/file[!].txt",
        "docs/file[z-a].txt", "docs/*file[z-a].txt",
        "docs/f[o][o].txt", "docs/file[]-a].txt",
        "docs/[[:digit:]].txt", "docs/[[:bogus:]]*.txt",
        "docs/[[.a.]].txt", "docs/[[=a=]].txt",
        "docs/[]", "docs/[!]", "docs/[a-]", "docs/[-a]",
        "docs/no" + "\\", "docs/*" + "\\",
        r"docs/**/\[draft\].txt", r"docs/**/*\[draft\].txt",
        r"docs/**\*.txt", r"docs/*\?.txt",
    ]
    for index, body in enumerate(bodies):
        add("boundary-default-%02d" % index, [":(top)" + body])
        add("boundary-glob-%02d" % index, [":(top,glob)" + body])

    add("literal-and-glob-union", [
        ":(top,literal)docs/*.txt", r":(top,glob)docs/*\[draft\].txt"])
    add("exclude-before-positive", [
        r":(top,exclude)docs/*\[draft\].txt", ":(top,glob)docs/**"])
    add("exclude-after-literal-identity", [
        ":(top)docs/f[o][o].txt", ":(top,exclude,literal)docs/f[o][o].txt"])
    add("attr-set-escaped", [r":(top,glob,attr:publish)docs/*\[draft\].txt"])
    add("attr-unset-escaped", [r":(top,glob,attr:-generated)docs/*\[draft\].txt"])
    add("attr-unspecified", [r":(top,attr:!publish)src/*\[draft\].txt"])
    add("attr-value-escaped", [r":(top,attr:kind=text)docs/*\[draft\].txt"])
    add("attr-compound-exclude", [
        r":(top,glob,attr:publish -generated kind=text)docs/*\[draft\].txt",
        ":(top,exclude,literal)docs/skip[draft].txt"])
    add("prefix-top-raw", [r":(top,glob)docs/*\[draft\].txt"], prefix="src/lib")
    add("literal-prefix-magic", [
        ":(top,prefix:0,literal)docs/[draft].txt"], prefix="src/lib")
    add("global-literal", ["docs/[draft].txt"], options={"literal": True})
    add("global-literal-disables-magic", [":(glob)docs/*"], options={"literal": True})
    add("global-glob", [r":(top)docs/*\[draft\].txt"], options={"glob": True})
    add("global-noglob-literal-name", ["docs/*.txt"], options={"noglob": True})
    add("global-noglob-explicit-glob", [r":(top,glob)docs/*\[draft\].txt"],
        options={"noglob": True})
    add("global-icase-escape", [r":(top)DOCS/*\[DRAFT\].TXT"], options={"icase": True})
    add("global-glob-icase", [":(top)DOCS/*.TXT"],
        options={"glob": True, "icase": True})
    add("global-conflicting-literal-glob", ["docs/*"],
        options={"literal": True, "glob": True})
    add("global-conflicting-glob-noglob", ["docs/*"],
        options={"glob": True, "noglob": True})

    # An actual POSIX argv is essential here. On Windows these must be not_run;
    # top normalization is not substituted and called equivalent execution.
    for prefix, relative in [("docs", r"*\[draft\].txt"),
                             ("src", r"../docs/*\[draft\].txt"),
                             ("src/lib", r"../../docs/*\[draft\].txt")]:
        add("posix-relative-" + prefix.replace("/", "-"),
            [":(glob)" + relative], prefix=prefix, mode="posix")
    add("posix-escaped-backslash", [r":(top)docs/back\\slash.txt"], mode="posix")
    add("posix-trailing-backslash-identity", [":(top)docs/trail\\"], mode="posix")
    add("posix-star-backslash-identity", [":(top)docs/*\\"], mode="posix")

    for index, body in enumerate([
        r"docs/\[draft\].txt", r"docs\*.txt", r"docs\*\[draft\].txt",
        r"docs\..\docs\[draft].txt",
    ]):
        add("windows-preprocessing-%02d" % index, [body],
            options={"windows": True}, mode="windows")
    add("windows-relative-prefix", [r"..\docs\*.txt"], prefix="src",
        options={"windows": True}, mode="windows")
    for index, raw in enumerate([
        "", "true", "false", "yes", "no", "on", "off", "TRUE", "FaLsE", "1", "0", "-1",
        "+1", "01", "0x1", "010", "08", "0b1", "1k", "0k", "-2g", "2g", "2147483647",
        "-2147483648", "2147483648", "1.0", "not-a-bool", " yes", "true ", " 1", "1 ",
        "1K", "1m", "1G", "0B1", "0b0", "-0b10", "+0b1", "0b2", "0b", "0b1k",
        "0b10000000000000000000000000000000", "-0b10000000000000000000000000000000",
    ]):
        cases.append({"id": "environment-icase-%02d" % index, "category": "environment",
                      "patterns": [":(top)DOCS/*.TXT"], "prefix": "", "options": {},
                      "environment": {"GIT_ICASE_PATHSPECS": raw}, "mode": "all"})
    for field, variable in [("literal", "GIT_LITERAL_PATHSPECS"), ("glob", "GIT_GLOB_PATHSPECS"),
                            ("noglob", "GIT_NOGLOB_PATHSPECS"), ("icase", "GIT_ICASE_PATHSPECS")]:
        for raw in ["true", "false"]:
            cases.append({"id": "environment-" + field + "-" + raw, "category": "environment",
                          "patterns": ["docs/*.txt"], "prefix": "", "options": {},
                          "environment": {variable: raw}, "mode": "all"})
        cases.append({"id": "environment-overridden-" + field, "category": "environment",
                      "patterns": ["docs/*.txt"], "prefix": "", "options": {field: False},
                      "environment": {variable: "invalid"}, "mode": "all"})
    for prefix_bytes in [0, 1, 4, 5, 6, 7, 8]:
        for body in [r"docs/a\[b].txt", "docs/a[b].txt", "docs/*.txt"]:
            add("protected-prefix-%d-%d" % (prefix_bytes, len(cases)),
                [":(prefix:%d,icase)" % prefix_bytes + body])
    for glob_mode in ["top", "top,glob", "top,icase", "top,glob,icase"]:
        for body in [r"docs/**\/a[draft].txt", r"docs/\U*.TXT", r"docs/\u*.TXT",
                     "docs/[A-Z]*.TXT", "docs/[A]*.TXT", "docs/[[:upper:]]*.TXT"]:
            add("case-range-escape-%d" % len(cases), [":(" + glob_mode + ")" + body])
    add("bare-colon-with-exclusion", [":", ":(exclude)docs"], prefix="src")
    add("empty-pattern-error", [""])
    add("attribute-escaped-comma", [r":(top,attr:kind=a\,b)docs/*.txt"])
    return cases


def generated_cases(seed, count):
    rng = random.Random(seed)
    bodies = [
        r"docs/*\[draft\].txt", r"docs/*\?report.txt", r"docs/*\*report.txt",
        r"docs/\[draft\].txt", r"docs/a\?report.txt", r"docs/a\*report.txt",
        "docs/f[o][o].txt", "docs/file[z-a].txt", "docs/a[broken",
        "docs/[!]", "docs/[a-]", "docs/[-a]", "docs/[[:digit:]].txt",
        "docs/[[:alpha:]]*.txt", "docs/[[:bogus:]]*.txt",
        r"docs/**/\[draft\].txt", r"docs/**/*\[draft\].txt",
        "docs/no" + "\\", "docs/*" + "\\", "docs/*", "docs/**",
        "docs/*.txt", "assets/*", "src/**", "LICENSE",
    ]
    magics = ["top", "top,glob", "top,literal", "top,icase",
              "top,glob,icase", "top,attr:publish -generated",
              "top,glob,attr:kind=text", "top,attr:!missing"]
    globals_ = [{}, {}, {}, {"glob": True}, {"noglob": True},
                {"icase": True}, {"glob": True, "icase": True}]
    for index in range(count):
        patterns = []
        for item in range(rng.randint(1, 3)):
            magic = rng.choice(magics)
            if item and rng.randrange(3) == 0:
                magic += ",exclude"
            patterns.append(":(" + magic + ")" + rng.choice(bodies))
        yield {"id": "generated-%03d" % index, "category": "fixed-seed-combination",
               "patterns": patterns, "prefix": rng.choice(["", "src", "docs", "src/lib"]),
               "options": rng.choice(globals_), "mode": "all"}


def check_response(actual, expected, paths):
    issues = []
    if not isinstance(actual, dict):
        return ["core response must be an object"]
    if actual.get("schema_version") != 1:
        issues.append("schema_version differs")
    if actual.get("exit_code") != expected["exit_code"]:
        issues.append("exit_code differs")
    if actual.get("selected") != expected["selected"]:
        issues.append("selected paths/order differs")
    if expected["exit_code"] == 0 and actual.get("exit_code") == 0:
        decisions = actual.get("decisions")
        if not isinstance(decisions, list) or len(decisions) != len(paths):
            issues.append("explanation does not cover all candidates")
        else:
            selected = set(expected["selected"])
            for index, (path, decision) in enumerate(zip(paths, decisions)):
                if (not isinstance(decision, dict) or decision.get("path") != path
                        or decision.get("selected") is not (path in selected)):
                    issues.append("explanation path/selected differs at %d" % index)
                    break
    if expected["exit_code"] == 2 and not isinstance(actual.get("error"), dict):
        issues.append("failed response must contain a structured error")
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git", default=shutil.which("git"))
    parser.add_argument("--node", default=shutil.which("node"))
    parser.add_argument("--platform", choices=["auto", "posix", "windows"], default="auto")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence/local/escaped-oracle.json")
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--generated", type=int, default=160)
    args = parser.parse_args()
    if not args.git or not args.node:
        parser.error("Git and Node executables are required")
    if not 0 <= args.generated <= 1000:
        parser.error("--generated must be between 0 and 1000")
    started = time.time()
    report = {"schema_version": 1, "kind": "independent-escaped-pathspec-git-differential",
              "run_id": str(uuid.uuid4()), "started_at": datetime.now(timezone.utc).isoformat(),
              "status": "running", "passed": False, "seed": args.seed,
              "generated_cases": args.generated, "cases": [], "not_run": [], "failures": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record():
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")

    record()
    try:
        version = subprocess.run([args.git, "--version"], capture_output=True, timeout=15,
                                 check=True).stdout.decode().strip()
        native = "windows" if os.name == "nt" or ".windows" in version.lower() else "posix"
        platform = native if args.platform == "auto" else args.platform
        if platform != native:
            raise RuntimeError("--platform cannot turn native %s Git into %s Git" % (native, platform))
        reference_version = "2.43.0" if version.startswith("git version 2.43.") else "2.56.0"
        node_version = subprocess.run([args.node, "--version"], capture_output=True,
                                      timeout=15, check=True).stdout.decode().strip()
        report.update({"git_version": version, "node_version": node_version,
                       "native_platform": native, "platform": platform, "reference_version": reference_version,
                       "oracle_command": "git [global pathspec flags] ls-files --full-name -z -- <patterns>",
                       "candidate_source": "index-only update-index -z --index-info",
                       "attribute_source": "actual git check-attr -z for every candidate/name",
                       "platform_boundary": "Windows raw matching uses top magic; native non-top POSIX argv is not_run on Windows"})
        fixture_bytes = (EXAMPLES / "expected.json").read_bytes()
        examples = json.loads(fixture_bytes.decode("utf-8"))
        first = json.loads((EXAMPLES / examples["cases"][0]["file"]).read_text(encoding="utf-8"))
        base_paths = first["paths"]
        with tempfile.TemporaryDirectory(prefix="moonpathspec-escaped-oracle-") as directory:
            base = VirtualIndex(Path(directory) / "examples", args.git, base_paths,
                                examples["independent_measurement"]["gitattributes"], platform, reference_version)
            broad = VirtualIndex(Path(directory) / "boundaries", args.git,
                                 broad_paths(base_paths, platform), ATTRIBUTES, platform, reference_version)
            jobs = []
            for scenario in examples["cases"]:
                request = json.loads((EXAMPLES / scenario["file"]).read_text(encoding="utf-8"))
                number = scenario["file"].split("-", 1)[0]
                mode = "posix" if number == "08" else "windows" if number == "13" else "all"
                case = {"id": "example-" + scenario["file"], "category": "published-example",
                        "patterns": request["patterns"], "prefix": request.get("prefix", ""),
                        "options": request.get("options", {}), "mode": mode}
                if request["paths"] != base_paths:
                    raise RuntimeError("Example candidate lists differ")
                for path, values in request.get("attributes", {}).items():
                    for name, value in values.items():
                        if base.attributes[path].get(name) != value:
                            raise RuntimeError("Example attributes differ from Git: " + path)
                jobs.append((base, case, scenario["selected"]))
            jobs.extend((broad, case, None)
                        for case in fixed_cases(platform) + list(generated_cases(args.seed, args.generated)))
            active = []
            for oracle, case, static_selected in jobs:
                if case["mode"] not in {"all", platform}:
                    report["not_run"].append({"id": case["id"], "required_platform": case["mode"],
                                              "reason": "requires actual native " + case["mode"] + " Git argv"})
                    continue
                request = oracle.request(case)
                expected = oracle.expected(request)
                active.append((oracle, case, request, expected, static_selected))
            report["fixtures"] = {
                "examples": {"paths": base.paths, "candidate_paths_sha256": digest(base.paths),
                             "attributes_sha256": digest(base.attributes)},
                "boundaries": {"paths": broad.paths, "candidate_paths_sha256": digest(broad.paths),
                               "attributes_sha256": digest(broad.attributes)},
            }
            report["example_expected_file_sha256"] = hashlib.sha256(fixture_bytes).hexdigest()
            report["generated_inputs_sha256"] = digest([
                {"patterns": case["patterns"], "prefix": case["prefix"], "options": case["options"], "environment": case.get("environment", {})}
                for _, case, _, _, _ in active if case["category"] == "fixed-seed-combination"
            ])
            for offset in range(0, len(active), 64):
                batch = active[offset:offset + 64]
                process = subprocess.run(
                    [args.node, str(ROOT / "scripts/request.mjs")], cwd=ROOT, env=broad.env,
                    input=json.dumps({"batch": [item[2] for item in batch]},
                                     ensure_ascii=False).encode("utf-8"),
                    capture_output=True, timeout=180
                )
                if process.returncode:
                    raise RuntimeError("Core runner failed: " +
                                       process.stderr.decode("utf-8", errors="replace"))
                envelope = json.loads(process.stdout.decode("utf-8"))
                responses = envelope.get("results") if isinstance(envelope, dict) else None
                if not isinstance(responses, list) or len(responses) != len(batch):
                    raise RuntimeError("Core batch must return one result per request")
                for (oracle, case, request, expected, static_selected), actual in zip(batch, responses):
                    issues = check_response(actual, expected, oracle.paths)
                    if static_selected is not None and expected["selected"] != static_selected:
                        issues.append("published fixed expectation differs from actual native Git")
                    entry = {"id": case["id"], "category": case["category"],
                             "prefix": case["prefix"], "patterns": case["patterns"], "environment": case.get("environment", {}),
                             "options": case["options"], "expected": expected,
                             "passed": not issues,
                             "actual": {key: actual.get(key) for key in
                                        ["schema_version", "exit_code", "selected", "error", "steps"]}
                             if isinstance(actual, dict) else actual}
                    report["cases"].append(entry)
                    if issues:
                        report["failures"].append({"id": case["id"], "issues": issues,
                                                   "request": request, "expected": expected,
                                                   "actual": actual})
                record()
            report["git_commands"] = base.commands + broad.commands
        report.update({"total_cases": len(jobs), "compared_cases": len(report["cases"]),
                       "not_run_cases": len(report["not_run"]),
                       "passed_cases": sum(case["passed"] for case in report["cases"]),
                       "failed_cases": len(report["failures"]),
                       "git_error_cases": sum(case["expected"]["exit_code"] == 2 for case in report["cases"]),
                       "status": "failed" if report["failures"] else "passed",
                       "passed": not report["failures"]})
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report.update({"status": "failed", "passed": False, "runner_error": str(error)})
    report["elapsed_seconds"] = round(time.time() - started, 3)
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    record()
    print(json.dumps({key: report[key] for key in [
        "status", "platform", "total_cases", "compared_cases", "not_run_cases",
        "passed_cases", "failed_cases", "git_error_cases", "runner_error"
    ] if key in report}, ensure_ascii=False))
    print(str(args.output.resolve()))
    for failure in report["failures"][:15]:
        print(failure["id"] + ": " + "; ".join(failure["issues"]))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
