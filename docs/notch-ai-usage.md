# AI usage in the notch

In **Notch → Home layout**, turn on **AI Usage** and choose which other widgets to show. In **Notch → AI Usage**, choose profiles, used or remaining percentages, and the limit windows to display. Edit a profile to choose a source folder or check its connection.

Orbit displays quota reported by the provider. Values reflect the latest local snapshot and expire when its reset time passes. A profile can have only one of the requested windows, and different providers can report different durations. Keep each account’s snapshots in a separate folder.

## Codex

The built-in profile uses `CODEX_HOME` when available to Orbit, or `~/.codex`. Choose a different Codex data folder for a separate profile. Orbit looks for quota snapshots in Codex’s local rollout logs. Some sessions omit quota snapshots. Open a session in Codex and make a request if the profile is waiting for data.

## Claude Code

The built-in profile uses `CLAUDE_CONFIG_DIR` when available to Orbit, or `~/.claude`. In the profile editor, choose **Copy Claude setup** to copy a `statusLine` settings snippet for the selected folder.

- If you have no status line, add the snippet’s `statusLine` entry to the existing Claude Code `settings.json` in the profile’s configuration folder.
- If you have a custom status line, keep its configuration and invoke the copied `command` from your existing script with the same JSON it receives on stdin. For example, a script that already saves the input in a shell variable can pipe it into the capture command with `printf '%s' "$input" | <command>`.
- Start a Claude Code session and make a request. Orbit checks for `orbit-quota.json` in the selected folder. The capture command writes the quota fields and capture time.

The snippet uses macOS’s system Perl. See the [Claude Code status line guide](https://code.claude.com/docs/en/statusline) for the provider’s setup and availability details.

## CodexBar or another provider

Add a profile with **CodexBar export** as its source and enter the provider ID, such as `grok` or `antigravity`. Configure the provider in CodexBar and export its documented JSON into the selected folder. Run the command again to update the snapshot. Keep one account per export. Orbit displays percentage windows returned for that provider. [CodexBar CLI documentation](https://github.com/steipete/CodexBar/blob/main/docs/cli.md)

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
