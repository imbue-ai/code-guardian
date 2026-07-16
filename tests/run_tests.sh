#!/usr/bin/env bash
#
# Run the stop hook test suite. No arguments runs everything; pass substrings
# to run a subset:
#
#   ./tests/run_tests.sh
#   ./tests/run_tests.sh config orchestrator

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_DIR="$TESTS_DIR/../plugins/imbue-code-guardian/scripts"

if ! command -v jq >/dev/null; then
    echo "jq is required" >&2
    exit 1
fi

failed=0
total=0

for f in "$TESTS_DIR"/test_*.sh; do
    name=$(basename "$f" .sh)
    if [[ $# -gt 0 ]]; then
        match=false
        for pat in "$@"; do
            [[ "$name" == *"$pat"* ]] && match=true
        done
        [[ "$match" == true ]] || continue
    fi
    total=$((total + 1))
    echo "$name"
    if ! bash "$f"; then
        failed=$((failed + 1))
    fi
done

echo
if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed of $total files"
    exit 1
fi
echo "OK: $total files"
