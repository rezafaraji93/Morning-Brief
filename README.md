# Morning Brief

A macOS menu bar app that writes you a calm one-page brief every weekday morning: your day drawn as terrain, then what needs you, what got resolved, and a few things worth a look. It reads your calendar, Slack, Granola, Linear and the rest through the AI agent you already have installed (**Claude Code** or **Codex**) and the connectors you've set up in it. The app holds no API keys of its own.

```
 8:00 ──► Morning Brief ──► your agent CLI (headless, read-only)
                               │  reads calendar · Slack · Granola · Linear … via its connectors
                               ▼
                           JSON brief (fixed schema) ──► drawn by the app's own template
                               ▼
        ~/Library/Application Support/MorningBrief/briefs/2026-10-20.html  + notification
```

The agent only gathers, sorts and writes the words; the app draws the page, so every brief looks the same whichever agent wrote it. Agent text is inserted as plain text, never as HTML.

## Install

1. Download the DMG from the latest [GitHub Release](../../releases) and drag **Morning Brief** onto **Applications**.
2. Open it. A sun appears in your menu bar. If macOS says it "can't verify" the app, go to **System Settings → Privacy & Security** and click **Open Anyway** once.

## First run

1. Click the sun, then the gear. **Agent** shows whether it found Claude Code and Codex; Automatic prefers Claude Code.
2. **Check what's connected** lists which tools serve calendar, chat, email, meeting notes and tasks, and which still need a sign-in. Add missing ones under **Add a tool**; you sign in once in the browser.
3. **Fill from your agent's memory** prefills your name and "About you"; edit as needed, and add **Extra sections** for anything specific, one per line.
4. **Suggest from Slack** fills in the channels to watch; add any it missed.
5. Click **Generate now**. The first brief takes about four minutes. After that it runs by itself at the time you set (8:00 on weekdays by default), or as soon as your Mac is properly awake and online, and retries if a run fails or starts without a tool that worked last time. Turn on **Launch at login**.

## What's in the brief

- **Needs attention:** things it would cost you to ignore today: someone blocked on you, a window closing, a meeting commitment coming due.
- **Resolved:** threads and questions that closed, with who closed them and the outcome.
- **From your meetings:** commitments you made in the last three weeks of meeting notes, with a countdown, unless a ticket already tracks them.
- **Worth a look:** gentle nudges about your own work in the watched channels: results, feedback, something shipped.
- **Flagged in Slack:** messages you reacted to with your to-do emoji (🔖 by default); remove the reaction when done. Slack reminders addressed to you or your team are picked up too. (Slack's To-dos list isn't readable by the agent; a to-do with a reminder set is, once Slackbot sends it.)
- **Your extra sections**, one per line in Settings, such as `#android-releases: anything shipped or rolled back`.

Watched Slack channels are read in full for the last working day (Friday to Sunday on a Monday), but only what concerns you makes the brief. Every item links back to its message, event, issue or doc, and has a tick: mark it done and it's struck through here and left out of the next briefs.

## Settings worth knowing

- **Model:** the recommended one is selected, with a note on the trade-off. Measured on Claude Code with the same brief: Opus gives the full brief (about 4 min, $2); Sonnet is fastest and accurate but delivers less (1½ min, 50¢); Haiku reads everything for 10¢ but gets details wrong; Fable is the same brief as Opus at twice the time and three times the cost.
- **While it writes**, the panel says what the agent is reading ("Skimming your Slack…"), from its live output. Each brief's tokens, cost and time show in the footer afterwards.
- **Add a tool:** Granola, Linear, Notion, Atlassian, Asana and Sentry sign in through the browser. Google Calendar and Slack only let approved apps sign in, so with Claude Code turn them on at claude.ai under Settings → Connectors. GitHub needs a personal access token; the app shows the command.
- **Prompt:** turn on "Use my own prompt" to edit a copy of the built-in instructions; placeholders like `{{NAME}}` and `{{SINCE}}` are filled in at run time, and "Reset to default" brings the built-in text back. "Copy today's full prompt" puts the exact text the agent will get on the clipboard.
- **Advanced:** the agent's program path (only if detection fails), extra command-line arguments, and the timeout.

## Safety

Every run is told it's read-only and treats everything it reads as data, never as instructions. Each agent runs in its most restrictive mode that can still read connectors:

| Agent | How it runs |
|---|---|
| Claude Code | `--permission-mode auto`; shell, editing, subagents, file search and web tools disallowed, and every connector tool that writes (Slack send/react/schedule, Calendar create/update/delete, Gmail send/trash/label, Linear save/delete, Notion create/update/delete, Granola folders) denied by name, so a run can only read |
| Codex | `exec --sandbox read-only --ephemeral` |

## Files

`~/Library/Application Support/MorningBrief/` holds `briefs/` (one self-contained `.html` plus `.json` per day; open or send them as they are) and `logs/` (each run's output; **Show Logs in Finder** in the panel menu). Look in the logs first if a run fails.

## Building and releasing

- **GitHub does it:** every push to `main` builds a universal DMG and publishes it as release `v0.1.<run number>`. Push a tag like `v1.0.0` to release under that version. Add the signing secrets listed at the top of `.github/workflows/release.yml` to get a notarized DMG that opens with no warnings.
- **Locally** (needs Xcode): `./scripts/build-app.sh` builds `dist/Morning Brief.app`; `./scripts/make-dmg.sh` wraps it in a DMG. Set `SIGN_IDENTITY` and `NOTARY_PROFILE` to sign and notarize.

## Developing

- `swift run` starts the app from the repo; resources load from `./Resources`. `MORNINGBRIEF_PANEL_WINDOW=1 swift run` also opens the panel as an ordinary window, for screenshots and UI work.
- The page design is `Resources/template.html`, the agent's instructions `Resources/prompt.md`, and the JSON contract `Resources/brief.schema.json` (regenerated by `python3 dev/make_schema.py`).
- Preview the template without an agent: `node dev/render.js Resources/template.html dev/samples/normal.json /tmp/brief.html 0 && open /tmp/brief.html`.

The design follows the original "morning" brief skill, dressed in the Polarsteps brand colours and fonts (Polarsteps Fellix and LORE Alternates, loaded from the Mac when installed).

## Contributing and license

Issues and pull requests are welcome; `swift build` and the notes above are all you need. The Fellix and LORE fonts are not included; the page uses them only if your Mac has them. MIT licensed, see [LICENSE](LICENSE).
