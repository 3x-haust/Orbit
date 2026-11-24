# AI usage in the notch

In **Notch → Home layout**, turn on **AI Usage** and choose which other widgets to show. In **Notch → AI Usage**, choose profiles, used or remaining percentages, and the limit windows to display. Edit a profile to choose a source folder or check its connection.

**Color by usage** colors the bars by remaining quota: deep green at 75% or more, light green at 50% to below 75%, orange at 25% to below 50%, and red below 25%. This color meaning stays the same in used-percentage mode. Turn it off for solid Orbit orange. The 5-hour and weekly windows share a row when space allows. Narrow widgets use small rings with percentages and reset countdowns; only the narrowest widths stack the limits. Countdown labels show whole days from 24 hours (`1d`, or `6d` for 150 hours), whole hours below one day such as `23h`, or minutes such as `48m` below one hour. Unknown or expired reset times are omitted.

Orbit displays quota reported by the provider. Values reflect the latest local snapshot and expire when its reset time passes. A profile can have only one of the requested windows, and different providers can report different durations. Keep each account’s snapshots in a separate folder.

## Codex

The built-in profile uses `CODEX_HOME` when available to Orbit, or `~/.codex`. Choose a different Codex data folder for a separate profile. When Codex is installed and signed in with ChatGPT, Orbit asks its app server for the current account quota. This works for shared plan usage from other clients, such as Pi or OpenCode, when Codex is signed in to the same account and workspace. Orbit also reads existing Codex rollout snapshots if the app server cannot be reached. A ChatGPT login in Pi or OpenCode alone does not sign Codex in.

## Claude Code

The built-in profile uses `CLAUDE_CONFIG_DIR` when available to Orbit, or `~/.claude`. Orbit reads Claude Code’s recent local quota cache automatically. Run `/usage` in Claude Code to refresh that cache.

For updates as you use Claude Code, edit the profile and click **Connect existing status line**. Orbit detects the user settings in the selected profile folder and wraps the existing command. Claude Code keeps displaying that command’s output, and Orbit saves its 5-hour and weekly quota data to `orbit-quota.json`. If the Claude Code session uses an API key or a keyless Claude Console OAuth login, Orbit can show the estimated cost for the latest session from `orbit-claude-cost.json`. The estimate comes from Claude Code’s status line and can differ from the API bill. **Disconnect status line** restores the previous command. The connection uses tools included with macOS and reads the quota fields Claude Code already sends to its status line.

Connecting, updating, or disconnecting rewrites `settings.json` with sorted keys and two-space indentation; existing values are preserved, but formatting and key order may change. The API authentication check inherits the running Claude Code session’s environment, including `CLAUDE_CONFIG_DIR` when set.

Project or managed settings can override your user status line. See the [Claude Code status line guide](https://code.claude.com/docs/en/statusline) and [settings precedence](https://code.claude.com/docs/en/settings).

## CodexBar or another provider

[CodexBar](https://github.com/steipete/CodexBar) is a separate open-source quota monitor. If you already use it, Orbit can read its exports. Add a profile with **CodexBar export** as its source and enter the provider ID, such as `grok` or `antigravity`. Configure the provider in CodexBar and export its documented JSON into the selected folder. Run the command again to update the snapshot. Keep one account per export. Orbit displays percentage windows returned for that provider. [CodexBar CLI documentation](https://github.com/steipete/CodexBar/blob/main/docs/cli.md)

```sh
codexbar usage --provider antigravity --json > /path/to/folder/.codexbar-next.json &&
  mv /path/to/folder/.codexbar-next.json /path/to/folder/codexbar-usage.json
```

For a custom exporter, select **Custom JSON** and write `orbit-quota.json` to the chosen folder. Publish the file atomically. Use one entry per duration, a used percentage from 0 to 100, and ISO 8601 timestamps. `resetAt` is optional. Supply the actual quota window length in minutes.

```json
{
  "version": 1,
  "observedAt": "2026-11-23T12:00:00Z",
  "windows": [
    { "minutes": 300, "usedPercent": 25, "resetAt": "2026-11-23T16:00:00Z" }
  ]
}
```
