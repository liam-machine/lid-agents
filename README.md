# Lid Agents

**Close your MacBook's lid and let your AI agents keep working.**

[![Download for macOS](https://img.shields.io/github/v/release/liam-machine/lid-agents?label=Download%20for%20macOS&logo=apple&style=for-the-badge&color=8a5a2b)](https://github.com/liam-machine/lid-agents/releases/latest/download/LidAgents.dmg)

Website: **[lid-agents.liam-is-an.ai](https://lid-agents.liam-is-an.ai)**

Claude Code, Codex and other terminal agents stop the moment you close the lid, because macOS sleeps. Lid Agents adds a coffee cup to your menu bar. Fill it (click, or press <kbd>⌃0</kbd>) and closing the lid turns the screen off but keeps the Mac awake **while an agent is busy**. When they've all finished, it switches itself back off and puts the closed Mac to sleep.

No external display, no keyboard or mouse plugged in, no power adapter required.

## Install

**[Download Lid Agents (.dmg)](https://github.com/liam-machine/lid-agents/releases/latest/download/LidAgents.dmg)**, drag it into Applications and open it. On first launch it asks once for your password (see [Permissions](#permissions-and-exactly-what-the-installer-changes)), and then the cup appears in your menu bar.

Or from a terminal:

```bash
curl -fsSL https://github.com/liam-machine/lid-agents/releases/latest/download/install.sh | bash
```

<sub>macOS 13 or later, Apple Silicon or Intel, on an administrator account. Signed with a Developer ID and notarized by Apple. Free and MIT licensed.</sub>

## How you use it

| You do | What happens |
|---|---|
| Click the cup → **When the lid closes** → **Keep running while agents work** (or press <kbd>⌃0</kbd>) | The cup fills in and shows how many agents are busy. Close the lid whenever. **Keep running for 3 hours** stays on even when no agent is working. |
| Close the lid while an agent works | The screen goes off; the agent keeps going. |
| Your agents finish | About 3 minutes later the cup empties, you get a notification, and a closed Mac goes to sleep. |
| Click the cup → **Sleep (normal)** (or press <kbd>⌃0</kbd> again) | Back to normal: closing the lid sleeps the Mac. |

The cup's menu also lists the agents that are running, each one **working** or **needs you**, and everything you set once is under **Settings**.

The same controls from a terminal:

```bash
agents keep            # keep running while agents are busy (8h cap)
agents keep 2h         # …with a 2-hour cap   (0 = no cap)
agents keep --always   # even when no agent is busy (3h)
agents pause           # normal lid-close sleep
agents                 # status
agents busy            # which agents count as busy (or need you), and in which folder
agents wait 10         # a closed Mac stays awake 10 min for an agent that needs you (default 3)
agents integrate       # let Lid Agents see when Codex and OpenCode are busy, and when an agent needs you
agents remote on       # new Claude Code sessions connect to Remote Control, so you can answer from your phone
agents hotkey ctrl+opt+cmd+l   # change the hotkey (or none); applies within seconds
agents update          # install the latest release
```

## Any terminal: Ghostty, cmux, Superset, IDEs

Lid Agents looks at processes, not at the app they run in, so agents count the same in Ghostty, cmux, Superset, Terminal, iTerm, tmux or an IDE's terminal. Wrappers that those apps put in front of `claude`, `codex` or `opencode` keep the agent's process name. Agents installed through npm, bun or pip run as `node` or `python`; for those the script name counts, so `node …/bin/gemini` is Gemini CLI.

## Codex and OpenCode

Claude Code tells Lid Agents when it's working. Codex and OpenCode don't by default, so a session waiting on the model or on a long test run can look idle. Run this once:

```bash
agents integrate
```

| Agent | What `agents integrate` does | Then |
|---|---|---|
| Codex | Runs `codex features enable prevent_idle_sleep`, Codex's own setting, in each Codex home it finds (`$CODEX_HOME`, `~/.codex`, and Superset's Codex account if you use one). Codex then holds a sleep assertion while a turn runs, which Lid Agents reads. | Busy for the whole turn in interactive sessions. `codex exec` doesn't take the assertion, so it counts only by CPU use. |
| OpenCode | Copies a small plugin to `~/.config/opencode/plugins/lid-agents.js`. It holds `caffeinate` while any session is busy, the same signal Claude Code gives. OpenCode loads it next to the plugins Superset and cmux add. | Busy for the whole task. |

Restart sessions that are already open to pick it up.

## When an agent needs you

An agent stopped on a permission prompt or a question isn't working: it's waiting for an answer. `agents integrate` tells Lid Agents when that happens, and the agent shows as **needs input** in `agents busy` and as **needs you** in the cup's **Agents** list.

- **Lid closed:** the Mac stays awake for **3 minutes** by default, so you have a moment to answer, for example from your phone, and then it sleeps unless something else is still working. Choose the time under the cup → **Settings** → **Wait for your answer** (3, 10, 30 or 60 minutes), or run `agents wait 10`. It applies straight away, even to a keep that's already running.
- **Lid open:** the agent counts as busy, because you may be there reading the prompt, so keep doesn't switch off under you.
- **You answered:** anything the agent starts afterwards that runs for 10 seconds or more, such as an approved test suite or `gh run watch`, means it's working again, even before its next hook fires. So a closed Mac doesn't sleep partway through an approved task.

| Agent | How it's told |
|---|---|
| Claude Code | Hooks in `~/.claude/settings.json`: its permission-prompt and question notifications mark it, its next event (a prompt, a tool finishing, the turn ending) clears it. |
| Codex | Hooks in `hooks.json` in each Codex home: `PermissionRequest` and its `request_user_input` question tool mark it, the next event clears it. Codex asks you to review new hooks once (`/hooks` in a Codex session); Codex started by Superset runs them as they are. |
| OpenCode | The same plugin, on `permission.asked` and `question.asked`. |

The hooks run `agents mark` and do nothing else: they print nothing, always succeed, and are tagged `# lid-agents-hook`, so re-running `agents integrate` replaces them and `agents uninstall` removes them, leaving any other hooks alone. The first change to each file keeps a `.lid-agents.bak` copy next to it. An agent that's using CPU again, or has started a long-running command since the prompt, counts as busy straight away. Editing a settings file never replaces it: an unreadable or invalid file is left alone, a file that wouldn't change isn't rewritten, and its permissions are kept.

## Answer from your phone

Close the lid, walk away, and still answer an agent that needs you. Claude Code's [Remote Control](https://code.claude.com/docs/en/remote-control) connects a session on your Mac to [claude.ai/code](https://claude.ai/code) and the Claude app for iOS and Android, and the app gets a push when the agent stops on a permission prompt or a question. Lid Agents keeps the Mac awake for it (see the wait time above) and turns it on for you:

- **Every new Claude Code session connects.** Once setup is done, Lid Agents asks you once, explaining what Remote Control does (it doesn't ask if you've already chosen in `/config`). Change it any time under the cup → **Settings** → **Connect new Claude sessions to your phone**, or with `agents remote on`. `agents integrate` turns it on too, unless you've already chosen either way. It sets Claude Code's own `remoteControlAtStartup` (the same as **Enable Remote Control for all sessions** in `/config`) and, unless you've chosen otherwise, **Push when actions required** (`inputNeededNotifEnabled`). `agents remote off` or the same menu item turns it off for new sessions.
- **Sessions that were already open are named.** Claude Code only connects a running session from inside it, so Lid Agents can't do it for you. When you switch keep on, the notification names any busy Claude session that isn't connected. In the cup's **Agents** list a connected Claude session has a phone in front of it and one that isn't has ⚠, and `agents` and `agents remote` name them too. Run `/remote-control` in each before you close the lid.

Remote Control needs a claude.ai Pro, Max, Team or Enterprise plan (Team and Enterprise: an Owner switches it on), and the Mac needs its own internet connection while the lid is closed. A session only appears in your own account. Lid Agents tells connected sessions apart by a field in Claude Code's `~/.claude/sessions/<pid>.json`, which isn't documented, so if a Claude Code update changes it, the warning stays quiet rather than wrong.

## Why this needs a tool

macOS has two kinds of sleep:

- **Idle sleep**, when nobody touches the Mac for a while. `caffeinate`, Amphetamine-style apps and Claude Code itself already block it. Claude Code runs `caffeinate -i -t 300` for as long as it's working.
- **Lid-close sleep**, triggered by the hardware lid sensor. No power assertion can override it. Apple only skips it in "clamshell mode", which needs an external display, keyboard, mouse **and** power.

The one switch that covers the lid is `pmset -a disablesleep 1`. It is global and easy to forget, which is the dangerous part: a Mac that stays awake in a bag gets hot and flattens its battery. Lid Agents handles it for you:

- **Only while agents work.** An agent counts as busy if it has a `caffeinate` child (Claude Code holds one only while working, and so does OpenCode with the plugin), holds a sleep assertion itself (Codex with `prevent_idle_sleep`), or uses 5% or more CPU. A session left open and idle in a terminal tab doesn't count.
- **Turns itself off** after 3 idle minutes, at the 8-hour cap, or when the battery reaches 15%. If the lid is closed when that happens, the Mac goes to sleep straight away.
- **The screen still turns off.** The lid sensor switches off the built-in display; only system sleep is held.

## Permissions, and exactly what the installer changes

| What | Why | Where |
|---|---|---|
| Your password, **once** (the installer, or the app's first-launch prompt) | Adds a sudoers rule allowing exactly `/usr/bin/pmset -a disablesleep 0` and `… 1`, nothing else. Sudo matches the arguments literally, so the rule can't be used for anything else. | `/etc/sudoers.d/lid-agents` |
| "Allow notifications" prompt | Notifications when you switch, and when it pauses itself | System Settings → Notifications → Lid Agents |
| Nothing else | The hotkey uses `RegisterEventHotKey`, which needs **no** Accessibility or Input Monitoring permission. | — |

Files: `Lid Agents.app` (in `/Applications` from the DMG, `~/Applications` from the one-liner), the `agents` link in `~/.local/bin`, a login item in `~/Library/LaunchAgents/io.github.liam-machine.lid-agents.plist`, and a log in `~/.cache/lid-agents/`. `agents integrate`, which you run yourself, adds `~/.config/opencode/plugins/lid-agents.js`, sets `prevent_idle_sleep` in `~/.codex/config.toml`, and adds tagged hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`. It and `agents remote` also set `remoteControlAtStartup` and `inputNeededNotifEnabled` in `~/.claude/settings.json`, Claude Code settings that `agents uninstall` leaves as they are. The app is built from this repo by GitHub Actions, signed with a Developer ID and notarized by Apple, so Gatekeeper opens it without warnings however you install it.

## Settings

| Setting | Default | How to change |
|---|---|---|
| Hotkey | ⌃0 | The cup → **Settings** → **Hotkey** → pick a preset, **None**, or **Record New Hotkey…** and press the keys you want; or `agents hotkey ctrl+opt+cmd+l` in a terminal. It applies immediately. It needs ⌃, ⌥ or ⌘ with a letter, number or Space. |
| Agents watched | `claude codex gemini aider opencode amp goose cursor-agent droid` | `AGENTS_NAMES` |
| Idle minutes before pausing | 3 | `AGENTS_IDLE_MINUTES` |
| CPU % that counts as busy (an agent plus its child processes) | 5 | `AGENTS_CPU` |
| Minutes a closed Mac stays awake for an agent that needs your answer | 3 | The cup → **Settings** → **Wait for your answer**, `agents wait 10`, or `AGENTS_WAIT_MINUTES` |
| Minutes an agent may sit "busy" at almost no CPU, usually waiting on you, before pausing | 30 | `AGENTS_QUIET_MINUTES` |
| Hard cap (hours) | 8 | `AGENTS_HOURS`, or `agents keep 4h` |
| Battery floor | 15% | `AGENTS_MIN_BATTERY` |

The `AGENTS_*` variables apply to the `agents` command in your shell. The menu bar app uses the defaults.

## Safety

- **Never put the Mac in a bag while the cup is full.** With the lid shut it can't get rid of heat. Lid Agents pauses when your agents finish, but a long task can still run for hours.
- Plug in for long runs, and run agents in `tmux` or a terminal that survives disconnects.
- Your lock screen still works: a closed, awake Mac is locked as usual.

## Updates

Once a day, Lid Agents asks GitHub's public API for the latest release. That one anonymous request sends nothing about you or your Mac. When there's a newer version, you get **one notification**, and **Update to x.y.z** appears at the top of the cup's menu. Clicking it installs the update and reopens the app a few seconds later, with no password. It never updates on its own. If an agent is running with the lid closed while it updates, it keeps running.

- Check now: the cup → **Settings** → **Check for Updates…**, or `agents update` in a terminal.
- Turn off the daily check: `defaults write io.github.liam-machine.lid-agents CheckForUpdates -bool false`

## Uninstall

```bash
agents uninstall
```

This switches lid-close sleep back on and removes the app, the command, the login item, the sudoers rule (asking for your password), the OpenCode plugin and the log. Codex's `prevent_idle_sleep` is a Codex setting, so it stays on; `codex features disable prevent_idle_sleep` turns it off.

## Troubleshooting

- **No cup in the menu bar.** Open **Lid Agents** from Applications (or Spotlight). The cup asks for a spot next to the clock, so it's the last item a full menu bar hides; if it's still hidden, ⌘-drag it further right, or turn other items off in System Settings → Menu Bar. The hotkey works either way.
- **The hotkey does nothing.** Another app may have claimed the same combination (Lid Agents tells you at launch when that happens). Pick a different one: `agents hotkey ctrl+opt+cmd+l`.
- **Switching shows no banner.** Notifications are off for Lid Agents: System Settings → Notifications → Lid Agents. `agents` shows the current state either way.
- **"Setup incomplete".** Run `agents install`.
- **Want to see what happened while the lid was closed?** Run `cat ~/.cache/lid-agents/lid-agents.log`.

## Building from source

```bash
git clone https://github.com/liam-machine/lid-agents && cd lid-agents
scripts/build.sh      # universal "build/Lid Agents.app", dist/LidAgents.dmg, dist/lid-agents.tar.gz
./install.sh          # installs the local build
tests/run.sh          # tests for bin/agents (detection, agents mark, hooks); see tests/README.md
```

**Releasing.** Every merge to `main` that changes the app is built by GitHub Actions, signed, notarized and published as the next patch release (latest tag + 1), with the DMG, the tarball and `install.sh`. Installed copies offer it within a day. Pushes that only change docs don't release. CI won't publish an unsigned release: the signing secrets come from `scripts/setup-signing-secrets.sh`, a one-time step for maintainers.

- Curated release notes: add a `## x.y.z` section to `CHANGELOG.md` before merging. Without one, GitHub writes the notes from the commits.
- Minor or major bump: set `VERSION` to e.g. `1.1.0`.
- Re-run a release by hand: Actions → *Build and release* → *Run workflow*.

## Credits

The `pmset disablesleep` approach and the narrow sudoers rule follow [Sleepless](https://github.com/Aboudjem/Sleepless). Lid Agents adds the agent awareness, so the Mac only stays awake while there's work being done.
