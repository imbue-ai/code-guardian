import { type Plugin } from "@opencode-ai/plugin"

// Stop-hook-equivalent workaround for opencode: opencode's plugin Hooks
// interface has no event that can block/force-continue a session (no
// Stop/session-end hook with an output channel -- confirmed by reading the
// actual typed Hooks interface). The only related hook, `event`, is purely
// observational.
//
// Workaround: opencode is client-server, and the plugin receives a live SDK
// `client` in its input. On session.idle (root session only), if gates
// aren't satisfied, use client.session.promptAsync to inject a new prompt
// back into the session -- the same mechanism opencode's own client-server
// model uses for delivering messages generally, just called from inside the
// plugin instead of over HTTP.
//
// Anti-loop safeguard: a flag file keyed on the current commit hash, in the
// user's own project (not this package), ensures each commit gets nagged at
// most once regardless of how many times the session goes idle without HEAD
// moving -- without it, the injected prompt making the session busy again
// could re-trigger the same idle event indefinitely.
//
// Path note: this file is loaded as an installed npm package, so the
// bundled config_utils.sh / stop_hook_gates.sh are resolved relative to
// THIS module's own location (import.meta.dir), not the user's project
// (`directory`, from PluginInput) -- `directory` is used only for
// operations that must run in the user's project (the git/gate-check
// invocation itself, and the nag-flag file).

const NAG_FLAG_DIR = ".reviewer/outputs"
const NAG_FLAG_FILE = `${NAG_FLAG_DIR}/.opencode_last_nagged_head`

export const ReviewerGatePlugin: Plugin = async ({ $, client, directory }) => {
  const pluginRoot = import.meta.dir
  const parentBySession = new Map<string, string | undefined>()

  const isRootSession = (sessionID: string): boolean => {
    const parentID = parentBySession.get(sessionID)
    return parentID === undefined || parentID === ""
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.created" || event.type === "session.updated") {
        const info = (event.properties as { info?: { id: string; parentID?: string } }).info
        if (info) parentBySession.set(info.id, info.parentID)
        return
      }

      if (event.type !== "session.idle") return
      const sessionID = (event.properties as { sessionID: string }).sessionID
      if (!isRootSession(sessionID)) return

      const enabledCheck = await $`bash -c '
        source "${pluginRoot}/scripts/config_utils.sh"
        enabled_when=$(read_json_config .reviewer/settings.json stop_hook.enabled_when "")
        [[ -n "$enabled_when" ]] && bash -c "$enabled_when"
      '`
        .cwd(directory)
        .quiet()
        .nothrow()
      if (enabledCheck.exitCode !== 0) return

      const gateCheck = await $`${pluginRoot}/scripts/stop_hook_gates.sh`.cwd(directory).quiet().nothrow()
      if (gateCheck.exitCode === 0) return // gates satisfied, nothing to do

      const headResult = await $`git rev-parse HEAD`.cwd(directory).quiet().nothrow()
      const head = headResult.stdout.toString().trim()
      if (!head) return

      const flagPath = `${directory}/${NAG_FLAG_FILE}`
      const lastNagged = await $`cat ${flagPath}`.quiet().nothrow()
      if (lastNagged.exitCode === 0 && lastNagged.stdout.toString().trim() === head) {
        return // already nagged this exact commit, avoid a re-prompt loop
      }

      await $`mkdir -p ${directory}/${NAG_FLAG_DIR}`.quiet().nothrow()
      await $`echo ${head} > ${flagPath}`.quiet().nothrow()

      const reason = gateCheck.stderr.toString().trim()
      await client.session.promptAsync({
        path: { id: sessionID },
        body: {
          parts: [
            {
              type: "text",
              text: reason || "Review gates have not been satisfied. See .reviewer/settings.json for what's required.",
            },
          ],
        },
      })
    },
  }
}
