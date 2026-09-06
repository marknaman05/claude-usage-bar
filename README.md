# Claude Usage Bar

A tiny macOS menu bar app that shows your **Claude Code usage** and **when it resets** — the same numbers you get from `/status`, always visible.

<img width="418" height="287" alt="image" src="https://github.com/user-attachments/assets/456239c2-66bf-4c86-88c2-2202bfdc2139" />


- **Session + weekly limits** with progress bars and live countdowns
- **Color coded** — normal under 80%, orange at 80%+, red at 95%+
- **Auto-refreshes** every 60s, on wake from sleep, and when you open the menu
- **No login of its own** — it reuses the token the `claude` CLI already stored in your Keychain
- **~600 lines of Swift, zero dependencies**, builds in a couple of seconds

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools — `xcode-select --install`
- [Claude Code](https://claude.com/claude-code) installed **and logged in** (run `claude` once)

## Install

```bash
git clone https://github.com/marknaman05/claude-usage-bar.git
cd claude-usage-bar
./build.sh
open -a ~/Applications/ClaudeUsage.app
```

That's it — the icon appears in your menu bar. Click it → **Launch at Login** so it starts automatically.

`./build.sh` compiles the app, bundles it, ad-hoc signs it, and installs to `~/Applications`. Pass a different destination if you want: `./build.sh /Applications`.

## Verify it works

```bash
~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe
```

Prints your current usage to the terminal and exits:

```
Session (5h)             5%  resets 21:49 (in 4h 46m)
Weekly (all models)     15%  resets Mon 06:29 (in 13h 26m)
```

If this works but the menu bar icon is missing, see [Troubleshooting](#troubleshooting).

## How it works

1. **Reads your token from the Keychain.** The `claude` CLI stores an OAuth access token under the service `Claude Code-credentials`. The app reads that same entry via the Security framework — it never asks you to log in separately.
2. **Calls the same endpoint `/status` uses:** `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`.
3. **Parses the `limits` array** from the response into labeled bars. New limit types (weekly Opus, weekly Sonnet, extra usage credits) render automatically without a code change.
4. **Draws an `NSStatusItem`** with a compact title and builds the dropdown fresh on each open.

Everything happens locally. The only network call is to Anthropic's own API, with your own token — the same trust boundary as the CLI itself.

## Privacy & security

- **No secrets are stored in this repo or by the app.** The token is read from the Keychain at runtime and held in memory only.
- **Nothing is sent anywhere except `api.anthropic.com`.** No analytics, no telemetry, no third-party services.
- **No Screen Recording, Accessibility, or Full Disk Access needed.** The only permission is Keychain read access, which macOS may prompt for once on first launch.
- The app is **ad-hoc signed** (`codesign -s -`) so the Keychain grant persists across launches. Re-run `./build.sh` after editing and macOS may prompt once more, since the signature changes.

## Troubleshooting

**Icon doesn't appear, or vanished**

macOS silently hides menu bar items when there's no room — no overflow arrow for third-party apps. This is most common on notched Macs, where items only get the strip right of the notch. Fixes:

- Quit another menu bar app, or ⌘-drag icons to rearrange
- Reset preferences if a setting made the title too wide to fit:
  ```bash
  ~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --reset
  ```
  Then relaunch. This works even when the icon isn't clickable.

**Shows `⚠ auth`**

Your token expired or isn't there. Run `claude` once to refresh it — the app picks up the new token on its next refresh.

**Shows `—`**

A network or API error. Open the menu to see the specific reason.

**`swiftc: command not found`**

Install the Command Line Tools: `xcode-select --install`

## Uninstall

```bash
pkill -f ClaudeUsage
rm -rf ~/Applications/ClaudeUsage.app
defaults delete local.claude-usage-bar
```

## Notes

`/api/oauth/usage` is an internal endpoint used by Claude Code itself, not a documented public API. It could change without notice. The app degrades gracefully if it does — it falls back to older response shapes and shows an error in the menu rather than crashing.

## License

MIT — see [LICENSE](LICENSE).
