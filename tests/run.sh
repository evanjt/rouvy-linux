#!/usr/bin/env bash
# Run the tests. The test-wine-*.sh scripts need a built Wine, one of them
# an installed Rouvy, so they only run when asked.
#
# Usage:
#   tests/run.sh            the guards only
#   tests/run.sh --wine     the guards and test-wine-*.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WITH_WINE=0
[[ ${1:-} == --wine ]] && WITH_WINE=1
passed=0
failed=()
for t in "$ROOT"/tests/test-*.sh; do
    name=${t##*/}
    [[ $name == test-wine-*.sh && $WITH_WINE -eq 0 ]] && continue
    printf '%-32s ' "$name"
    if out=$(cd "$ROOT" && "$t" 2>&1); then
        echo ok
        passed=$((passed + 1))
    else
        echo FAIL
        printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
        failed+=("$name")
    fi
done
echo "$passed passed${failed:+, ${#failed[@]} failed}"
[[ ${#failed[@]} -eq 0 ]] && exit 0
echo "failed: ${failed[*]}" >&2
exit 1
