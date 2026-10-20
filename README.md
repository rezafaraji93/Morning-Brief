# Morning Brief

A macOS menu bar app that writes you a calm one-page brief every weekday morning: your day drawn as terrain, then what needs you and what's already sorted. It pulls from your calendar, Slack, Granola, Linear and the rest of your tools.

It doesn't hold any API keys or connect to Slack or Google itself. It drives the AI agent you already have installed (**Claude Code**, **Codex** or **Gemini CLI**), using the connectors you've already set up in that agent.

```
 8:00 ──► Morning Brief ──► your agent CLI (headless, read-only)
                               │  reads calendar · Slack · Granola · Linear … via its MCP connectors
                               ▼
                           JSON brief (fixed schema)
                               │
          template.html ◄──────┘  the app draws the page itself: terrain, lists, links
                               ▼
        ~/Library/Application Support/MorningBrief/briefs/2026-10-20.html  + notification
```

The agent only gathers, sorts and writes the words. The page is drawn by the app's own template, so every brief looks the same whichever agent wrote it. Agent text is inserted as plain text, never as HTML.

## Install

1. Download `MorningBrief-x.y.z.dmg`, from the GitHub Release or wherever it was shared.
2. Double-click it and drag **Morning Brief** onto **Applications**.
3. Open it from Applications. A sun appears in your menu bar.

If macOS says it "can't verify" the app, the DMG wasn't notarized. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

### Making the DMG

- **Easiest: let GitHub build it.** Push this repo to GitHub. `.github/workflows/release.yml` builds a universal DMG on GitHub's Macs for every push to `main`, attached to the run under **Artifacts**. Push a tag like `v0.1.0` and it's also published as a Release, with a link you can share. Add the signing secrets listed at the top of the workflow and the DMG is signed and notarized, so it opens with no warnings.
- **On your Mac** (needs Xcode Command Line Tools): run `./scripts/make-dmg.sh`. Add `SIGN_IDENTITY` and `NOTARY_PROFILE` to get a notarized DMG (see "Sharing it with the team").
- **Just for yourself:** run `./scripts/build-app.sh` and move `dist/Morning Brief.app` to Applications.

## First run

1. Click the menu bar sun, then **Settings…**
2. Under **Agent**, it shows which of `claude`, `codex` and `gemini` it found. Keep **Automatic** (it prefers Claude, then Codex, then Gemini) or pick one.
3. Click **Check Connections**. The agent lists which tools it can see for calendar, chat, email, meeting notes and tasks. If something says "not connected", see below.
4. Fill in **About you**, for example *"Android engineer on the Users team; include Linear issues assigned to me."* Optionally add **Extra sections**, one per line, such as `#android-releases: anything shipped or rolled back`.
5. Click **Generate Now** in the menu. The first run takes 2 to 5 minutes. After that it runs on its own at the time you set (default 8:00 on weekdays). If your Mac was asleep, it runs when the Mac wakes.

Turn on **Launch at login** so it's always there.

## Connecting your tools

The brief can only see what your agent can see.

- **Claude Code.** If you're signed in with your claude.ai account, the connectors you enabled on claude.ai (Slack, Google Calendar, Granola, Linear…) are normally available to `claude` too. Run `claude` once, type `/mcp` and check they're listed and authenticated. You can also add servers directly with `claude mcp add --transport http <name> <url>` (user scope).
- **Codex.** Add each server once with `codex mcp add <name> --url <url>`. The servers live in `~/.codex/config.toml`.
- **Gemini CLI.** Add servers in **user** scope: `gemini mcp add -s user -t http <name> <url>`. The app runs Gemini from its own folder, so project-scope servers won't be found.

Get each vendor's MCP URL from their docs (Slack, Granola, Linear and Notion all publish one).

## Safety

Each run is told it's read-only, and each agent runs in its most restrictive mode that can still read connectors:

| Agent | Flags the app uses |
|---|---|
| Claude Code | `-p --permission-mode auto --disallowedTools Bash Edit Write NotebookEdit --json-schema …` (falls back to `bypassPermissions` with the same tools disallowed if your build doesn't offer `auto`) |
| Codex | `exec --sandbox read-only --ephemeral --output-schema …` |
| Gemini CLI | `-p --approval-mode plan` (read-only) |

Slack messages and meeting notes are untrusted text. The prompt treats them as data and never as instructions. For extra safety you can expose only read tools to the agent, for example Gemini's `--exclude-tools` on `gemini mcp add`.

**If Gemini's plan mode blocks your connectors' read tools**, put `--approval-mode yolo` under **Extra arguments** (it replaces the default). That auto-approves every tool, so pair it with `--exclude-tools` on your servers' write tools. The same goes for Claude Code: a `--permission-mode` you set there replaces `auto`.

## Settings reference

- **Binary path:** use this if your agent isn't on your shell's PATH.
- **Model:** passed as `--model` (Claude), `-m` (Codex or Gemini).
- **Extra arguments:** appended to the command line. Shell-style quoting works, for example `--mcp-config ~/brief-mcp.json --strict-mcp-config`.
- **Include action buttons:** adds clay buttons on items Claude could move forward. Each one opens a prefilled Claude chat.
- **Give up after:** the timeout for a run (default 15 minutes).

## Files

- `~/Library/Application Support/MorningBrief/briefs/`: one `.html` and one `.json` per day. Each HTML file is self-contained, so you can open it in a browser or send it.
- `~/Library/Application Support/MorningBrief/logs/`: the agent's stdout and stderr for each run (**Show Logs in Finder**). Look here first if a run fails.

## Sharing it with the team

Engineers can build it themselves (above). To hand out a ready-made app that opens without Gatekeeper warnings, sign and notarize it with a Developer ID:

```bash
xcrun notarytool store-credentials morningbrief --apple-id you@company.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)" NOTARY_PROFILE=morningbrief \
ARCHS="arm64 x86_64" ./scripts/build-app.sh
```

Use `./scripts/make-dmg.sh` with those variables instead to get a notarized `dist/MorningBrief-0.1.0.dmg`. Or share `dist/MorningBrief-0.1.0.zip`. An unsigned zip downloaded from Slack is quarantined. People can still open it through **System Settings → Privacy & Security → Open Anyway**, or by running `xattr -dr com.apple.quarantine "/Applications/Morning Brief.app"`.

## Developing

- `swift run` starts the app straight from the repo. Resources load from `./Resources`, and notifications are off because there's no app bundle.
- The page design lives entirely in `Resources/template.html`, and the agent's instructions in `Resources/prompt.md`. The JSON contract is `Resources/brief.schema.json`, regenerated by `python3 dev/make_schema.py`.
- To preview the template without an agent:
  ```bash
  node dev/render.js Resources/template.html Resources/fraunces-latin-600-normal.woff2 dev/samples/normal.json /tmp/brief.html 0 && open /tmp/brief.html
  ```
  There are samples for normal, heavy (with an overlap), open, RTL and empty days.

The design follows the original "morning" brief skill: a hand-sketched terrain, one clay accent and Fraunces for the headline only.
