#!/usr/bin/env bash
# Fail when a compiled binary is tracked, or with --staged when one is staged (the pre-commit hook).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
if [[ ${1:-} == --staged ]]; then
    files=$(git diff --cached --name-only --diff-filter=AM)
else
    files=$(git ls-files)
fi
[[ -n $files ]] || exit 0
hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 file -- | grep -E ':.*(ELF|PE32|MS-DOS executable|Mach-O)')
[[ -z $hits ]] && exit 0
echo "Compiled binaries do not belong in this repository:" >&2
echo "$hits" >&2
exit 1
