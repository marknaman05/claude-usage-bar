# Setup prompt

Copy everything in the block below and paste it into Claude Code (or any AI coding assistant with terminal access) running on your Mac. It will install and launch the app for you.

---

```text
Set up the Claude Usage Bar menu bar app on my Mac. It's a macOS menu bar app that
shows my Claude Code usage percentage and when the limit resets.

Repo: https://github.com/marknaman05/claude-usage-bar

Please do all of this:

1. Check prerequisites and tell me if any are missing:
   - macOS 13 or later (`sw_vers`)
   - Swift compiler available (`swift --version`); if missing, tell me to run
     `xcode-select --install`
   - Claude Code is logged in — verify a Keychain entry exists with:
     `security find-generic-password -s "Claude Code-credentials" 2>&1 | head -3`
     Do NOT print the password/token itself, just confirm the entry exists.
     If it's missing, tell me to run `claude` once and log in.

2. Clone the repo into a sensible directory and run `./build.sh`. This compiles a
   single Swift file, makes an .app bundle, ad-hoc signs it, and installs it to
   ~/Applications.

3. Verify it actually works before declaring success:
   `~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe`
   This should print my current session and weekly usage with reset times. If it
   prints "NO AUTH" or "FAILED", debug that before continuing.

4. Launch it: `open -a ~/Applications/ClaudeUsage.app`, then confirm the process is
   running with `pgrep -fl ClaudeUsage`.

5. Tell me to look at the right side of my menu bar for text like "80% · 5m", and to
   click it and enable "Launch at Login" so it survives reboots.

Important notes for you:
- The app has no dock icon (LSUIElement), so it only appears in the menu bar.
- `screencapture` may not capture the menu bar status item layer, so don't rely on
  screenshots to verify — use the `--probe` command instead.
- Never print my OAuth token to the terminal at any point.
- If the icon doesn't show up, it's usually because my menu bar is full — macOS hides
  items with no room and gives no overflow arrow. Tell me to quit another menu bar app.
  The escape hatch if a setting made it too wide is:
  `~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --reset`
```

---

## If you'd rather just run it yourself

```bash
git clone https://github.com/marknaman05/claude-usage-bar.git
cd claude-usage-bar
./build.sh
~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --probe   # sanity check
open -a ~/Applications/ClaudeUsage.app
```

## Prompt to rebuild it from scratch

If you'd rather have an AI write the app itself instead of cloning:

```text
Build me a macOS menu bar app in Swift that shows my Claude Code usage and reset times.

Data source: the Claude Code CLI stores an OAuth access token in the macOS Keychain
under the generic-password service name "Claude Code-credentials". The value is JSON
containing `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt` (epoch ms). Use
that token as a bearer token to call:

  GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer <token>
  anthropic-beta: oauth-2025-04-20

The response contains a `limits` array of objects with `kind` ("session",
"weekly_all", ...), `group` ("session" / "weekly"), `percent`, and `resets_at` (ISO
8601). It also has legacy `five_hour` / `seven_day` objects with `utilization` and
`resets_at` — support those as a fallback.

Requirements:
- NSStatusItem menu bar app, LSUIElement (no dock icon), no external dependencies
- Menu bar title: session percent plus a countdown to reset, e.g. "80% · 5m"
- Title text turns orange at 80% and red at 95%
- Dropdown: one row per limit with a unicode progress bar, percentage, reset clock
  time and countdown
- Menu actions: Refresh Now (⌘R), a toggle to show weekly in the bar, Launch at Login
  via SMAppService, open https://claude.ai/settings/usage, Quit
- Refresh every 60s, on NSWorkspace.didWakeNotification, and on menu open if stale
- A `--probe` CLI flag that fetches once, prints the results, and exits
- A `--reset` CLI flag that clears UserDefaults (escape hatch if the icon gets hidden)
- Build script that compiles with swiftc, makes the .app bundle with an Info.plist,
  ad-hoc signs it (`codesign -s -`) so the Keychain grant sticks, installs to
  ~/Applications

Critical design constraint: menu bar space is scarce, and macOS silently hides status
items that don't fit (no overflow arrow for third-party apps). So the weekly toggle
must REPLACE the countdown rather than append to it, keeping the title width constant.
```
