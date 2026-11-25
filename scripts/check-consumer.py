"""Extract the real moon package and consume only its public API."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--moon', default=os.environ.get('MOONPATHSPEC_MOON', 'moon'))
    args = parser.parse_args()
    version = json.loads((ROOT / 'package.json').read_text(encoding='utf8'))['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise RuntimeError('Invalid release version')
    archive_path = ROOT / ('_build/publish/2111950632-moonpathspec-' + version + '.zip')
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
    manifest = manifests[0].read_text(encoding='utf8')
    if not re.search(r'^name\s*=\s*"2111950632/moonpathspec"\s*$', manifest, re.M) or not re.search(r'^version\s*=\s*"' + re.escape(version) + r'"\s*$', manifest, re.M):
        raise RuntimeError('Extracted package name/version differs from the current release')
    consumer = folder / 'consumer'
    consumer.mkdir()
    (folder / 'moon.work').write_text('members = ["' + module.relative_to(folder).as_posix() + '", "consumer"]\n', encoding='utf8')
    (consumer / 'moon.mod').write_text('name = "moonpathspec-validation/consumer"\nversion = "0.1.0"\nimport { "2111950632/moonpathspec@' + version + '" }\n', encoding='utf8')
    (consumer / 'moon.pkg').write_text('import { "2111950632/moonpathspec", "moonbitlang/core/json" } for "test"\n', encoding='utf8')
    fixture = ROOT / 'tests/registry_consumer.mbt.fixture'
    (consumer / 'consumer_test.mbt').write_text(fixture.read_text(encoding='utf8'), encoding='utf8')
    for target in ['js', 'wasm-gc']:
        subprocess.run([args.moon, 'test', '--target', target, '--deny-warn'], cwd=consumer, check=True, timeout=180)
    count = len(re.findall(r'^test ', fixture.read_text(encoding='utf8'), re.M))
    print(f'Real packaged public-API consumer passed on JS and Wasm GC ({count} own tests per target).')

if __name__ == '__main__':
    main()
