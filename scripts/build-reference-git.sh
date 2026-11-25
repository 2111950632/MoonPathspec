#!/usr/bin/env bash
# Build an isolated POSIX Git reference, never a dependency of the MoonBit library.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <2.43.0|2.56.0> <temporary-work-root> <evidence-directory>" >&2
  exit 2
fi
version=$1
work_root=$2
evidence_dir=$3

# Pinned from the official HTTPS checksum manifest on 2026-11-25:
# https://www.kernel.org/pub/software/scm/git/sha256sums.asc
# The archives were also downloaded and hashed independently before pinning.
# This checks SHA-256 integrity; it does NOT claim PGP signature verification.
case "$version" in
  2.43.0) expected_sha256=5446603e73d911781d259e565750dcd277a42836c8e392cac91cf137aa9b76ec ;;
  2.56.0) expected_sha256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3 ;;
  *) echo "Unsupported reference version: $version" >&2; exit 2 ;;
esac
if [[ $(uname -s) != Linux ]]; then
  echo "This reference build requires Linux; Windows Git has different path normalization." >&2
  exit 2
fi

mkdir -p "$work_root" "$evidence_dir"
work_root=$(cd "$work_root" && pwd -P)
evidence_dir=$(cd "$evidence_dir" && pwd -P)
build_root=$(mktemp -d "$work_root/git-$version.XXXXXX")
archive_name="git-$version.tar.xz"
archive="$build_root/$archive_name"
source_url="https://www.kernel.org/pub/software/scm/git/$archive_name"
checksum_url=https://www.kernel.org/pub/software/scm/git/sha256sums.asc
source_dir="$build_root/git-$version"
install_dir="$build_root/installed"

curl --fail --show-error --location --retry 3 --connect-timeout 20 --max-time 180 \
  "$source_url" -o "$archive"
curl --fail --show-error --location --retry 3 --connect-timeout 20 --max-time 120 \
  "$checksum_url" -o "$evidence_dir/official-sha256sums.asc"
manifest_sha256=$(awk -v file="$archive_name" '$2 == file { print $1 }' \
  "$evidence_dir/official-sha256sums.asc")
if [[ "$manifest_sha256" != "$expected_sha256" ]]; then
  echo "The official manifest does not contain the pinned archive checksum." >&2
  exit 1
fi
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check - \
  | tee "$evidence_dir/archive-check.log"
printf '%s  %s\n' "$expected_sha256" "$archive_name" > "$evidence_dir/git-source.sha256"
tar -xJf "$archive" -C "$build_root"

# Git's INSTALL documents these optional-library switches. zlib is required.
# Use identical switches and prefix for build/install; no HTTP or GUI tools needed.
make_options=(
  "prefix=$install_dir"
  NO_CURL=YesPlease NO_EXPAT=YesPlease NO_OPENSSL=YesPlease
  NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease
)
{
  uname -a
  cc --version
  make --version
  printf 'make options:'
  printf ' %q' "${make_options[@]}"
  printf '\n'
} > "$evidence_dir/build-environment.txt"
make -C "$source_dir" -j"${BUILD_JOBS:-2}" "${make_options[@]}" all 2>&1 \
  | tee "$evidence_dir/build.log"
make -C "$source_dir" "${make_options[@]}" install 2>&1 \
  | tee "$evidence_dir/install.log"
reference_git="$install_dir/bin/git"
actual_version=$("$reference_git" --version)
if [[ "$actual_version" != "git version $version" ]]; then
  echo "Unexpected reference version: $actual_version" >&2
  exit 1
fi
"$reference_git" version --build-options | tee "$evidence_dir/git-version.txt"
sha256sum "$reference_git" > "$evidence_dir/git-executable.sha256"
python3 - "$version" "$source_url" "$checksum_url" "$expected_sha256" \
  "$reference_git" "$evidence_dir/reference-git.json" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

version, source_url, checksum_url, source_sha256, executable, output = sys.argv[1:]
record = {
    "schema_version": 1,
    "kind": "source-built-posix-git-reference",
    "version": version,
    "source_url": source_url,
    "checksum_source_url": checksum_url,
    "source_sha256": source_sha256,
    "source_checksum_verified": True,
    "pgp_signature_verified": False,
    "executable": executable,
    "executable_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
    "build_options": subprocess.check_output(
        [executable, "version", "--build-options"], text=True).splitlines(),
}
Path(output).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
PY
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'git=%s\n' "$reference_git" >> "$GITHUB_OUTPUT"
fi
printf 'Reference Git: %s\n' "$reference_git"
