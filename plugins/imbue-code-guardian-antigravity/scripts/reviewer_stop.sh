#!/usr/bin/env bash
#
# reviewer_stop.sh (antigravity)
#
# Stop hook: gate-check port, same scope as the codex variant's
# reviewer_stop.sh (see that file's header for what is and is not ported).
# Unlike codex, antigravity's Stop hook contract is JSON-only --
# {"decision": "continue", "reason": ...} blocks the stop and re-enters the
# loop; no confirmed bare exit-code fallback -- so stop_hook_gates.sh's
# exit-2/stderr result is translated into that shape here rather than
# reused directly.
set -euo pipefail

cat > /dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config_utils.sh
source "$SCRIPT_DIR/config_utils.sh"

REVIEWER_SETTINGS=".reviewer/settings.json"

ENABLED_WHEN=$(read_json_config "$REVIEWER_SETTINGS" "stop_hook.enabled_when" "")
if [[ -z "$ENABLED_WHEN" ]]; then
    exit 0
fi
if ! bash -c "$ENABLED_WHEN" 2>/dev/null; then
    exit 0
fi

exit_code=0
reason=$("$SCRIPT_DIR/stop_hook_gates.sh" 2>&1 >/dev/null) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    jq -n --arg reason "$reason" '{decision: "continue", reason: $reason}'
fi

exit 0
