"""Extract the real moon package and consume only its public API."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--moon', default=os.environ.get('MOONPATHSPEC_MOON', 'moon'))
    args = parser.parse_args()
    archive_path = ROOT / '_build/publish/2111950632-moonpathspec-0.1.0.zip'
    if not archive_path.is_file():
        raise RuntimeError('Run moon package first')
    parent = ROOT / '_build/consumer-check'
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix='case-', dir=parent))
    package = folder / 'package'
    package.mkdir()
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            if not (package / member.filename).resolve().is_relative_to(package.resolve()):
                raise RuntimeError('Archive path leaves the extraction directory')
        archive.extractall(package)
    manifests = list(package.rglob('moon.mod'))
    if len(manifests) != 1:
        raise RuntimeError('Expected exactly one packaged module')
    module = manifests[0].parent
    consumer = folder / 'consumer'
    consumer.mkdir()
    (folder / 'moon.work').write_text('members = ["' + module.relative_to(folder).as_posix() + '", "consumer"]\n', encoding='utf8')
    (consumer / 'moon.mod').write_text('name = "moonpathspec-validation/consumer"\nversion = "0.1.0"\nimport { "2111950632/moonpathspec@0.1.0" }\n', encoding='utf8')
    (consumer / 'moon.pkg').write_text('import { "2111950632/moonpathspec" } for "test"\n', encoding='utf8')
    (consumer / 'consumer_test.mbt').write_text('''test "public selection and explanation" {
  let plan = @moonpathspec.compile([":(glob)**/*.mbt", ":(exclude)vendor"]).unwrap()
  let result = @moonpathspec.select(plan, ["main.mbt", "src/a.mbt", "vendor/a.mbt"]).unwrap()
  assert_eq(result.selected, ["main.mbt", "src/a.mbt"])
  let decision = @moonpathspec.explain(plan, "vendor/a.mbt").unwrap()
  assert_eq(decision.selected, false)
  assert_eq(decision.excluded_by, [1])
}
test "public four-state attributes" {
  let plan = @moonpathspec.compile([":(attr:publish -generated)src"]).unwrap()
  let result = @moonpathspec.select(plan, ["src/a"], attribute=fn(_, name) {
    if name == "publish" { @moonpathspec.AttributeValue::Set } else { @moonpathspec.AttributeValue::Unset }
  }).unwrap()
  assert_eq(result.selected, ["src/a"])
}
test "public parser and explicit unsupported diagnostics" {
  assert_eq(@moonpathspec.parse_pattern(":(top,literal)x").unwrap().magic.top, true)
  assert_true(@moonpathspec.compile([":(unknown)x"]) is Err(_))
  assert_true(@moonpathspec.compile(["x\\\\*"]) is Err(_))
}
test "public protocol and budgets" {
  let plan = @moonpathspec.compile(["*"], limits={ ..@moonpathspec.default_limits(), max_match_steps: 1 }).unwrap()
  assert_true(@moonpathspec.select(plan, ["long-name"]) is Err(_))
  let response = @moonpathspec.dispatch("{\\"patterns\\":[\\"a\\"],\\"paths\\":[\\"a\\",\\"b\\"]}")
  assert_true(response.contains("selected"))
}
''', encoding='utf8')
    for target in ['js', 'wasm-gc']:
        subprocess.run([args.moon, 'test', '--target', target, '--deny-warn'], cwd=consumer, check=True, timeout=180)
    print('Real packaged public-API consumer passed on JS and Wasm GC (4 own tests per target).')

if __name__ == '__main__':
    main()
