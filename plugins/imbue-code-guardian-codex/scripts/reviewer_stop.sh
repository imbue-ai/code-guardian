#!/usr/bin/env bash
#
# reviewer_stop.sh (codex)
#
# Stop hook: gate-check port of the claude plugin's stop_hook_orchestrator.sh
# Step 1 (enabled_when check) + stop_hook_gates.sh. Does NOT port the rest of
# the orchestrator (PR/CI polling, uncommitted-changes enforcement, base
# branch fetch/merge) -- gate-check only. codex accepts the same exit-code-2
# + stderr-reason contract as claude for its Stop hook, so stop_hook_gates.sh
# needs zero changes to work here -- this wrapper only adds the enabled_when
# gate stop_hook_gates.sh itself does not check.
set -euo pipefail

cat > /dev/null 2>&1 || true # drain stdin, unused by the gate check

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

exec "$SCRIPT_DIR/stop_hook_gates.sh"
