# Changelog

## 1.3.0

- **Answer agents from your phone.** Lid Agents turns on Claude Code's own [Remote Control](https://code.claude.com/docs/en/remote-control) for new sessions, so with the lid closed you can answer a Claude session from claude.ai/code or the Claude app, which gets a push when it needs you. After setup, Lid Agents asks once whether to turn it on, explaining what it does (unless you've already chosen in Claude Code's `/config`). Turn it on or off any time under the cup → **Settings** → **Connect new Claude sessions to your phone**, or with `agents remote on|off`. `agents integrate` turns it on unless you've already chosen. It sets `remoteControlAtStartup` and, unless you've chosen otherwise, `inputNeededNotifEnabled` in `~/.claude/settings.json`.
- **Busy sessions your phone can't reach are named.** Claude Code only connects a session that's already running from inside it, so when you switch keep on, the notification lists any busy Claude session that isn't on Remote Control, and so do the cup's menu, `agents` and `agents remote`. Run `/remote-control` in each before you close the lid.
- **Click an agent to go to it.** In the cup's **Agents** list, or `agents focus <pid>`. It brings up the app the agent runs in, whichever terminal or editor that is, found from its processes, and the agent's own tab where the app allows: cmux, Terminal and iTerm2 (macOS asks once to allow it), tmux (its pane, then the terminal that used it last), WezTerm and kitty.
- **A clearer menu.** Top to bottom: what's happening, **When the lid closes** (**Sleep (normal)**, **Keep running while agents work**, **Keep running for 3 hours**, with a tick on the one in use), the **Agents** that are running (each **working** or **needs you**, in full colour, with a phone in front of a Claude session on Remote Control and ⚠ in front of one that isn't), then **Settings** for the wait time, Remote Control, the hotkey, Open at Login, updates and the log. It opens faster too: one look at the processes instead of three.

## 1.2.0

- **Lid Agents knows when an agent needs you.** An agent stopped on a permission prompt or a question shows as **needs input** in `agents busy` and the cup's **Busy agents** menu (after busy agents). Run `agents integrate` to set it up:
  - **Claude Code** and **Codex** get hooks (in `~/.claude/settings.json` and each Codex home's `hooks.json`) that run when the agent stops on a prompt and when it moves on. They're tagged, print nothing and always succeed; your other hooks stay as they are, and a `.lid-agents.bak` copy is kept before the first change. Codex asks you to review new hooks once (`/hooks`).
  - **OpenCode**: the plugin does the same on its permission and question events, per request, and only while no other session is still working.
- **Choose how long to wait for you.** With the lid closed, a closed Mac stays awake **3 minutes** by default for an agent that needs your answer (enough to answer from your phone), then sleeps. Change it under the cup → **When an agent needs you** (3, 10, 30 or 60 minutes) or with `agents wait <minutes>`. With the lid open, an agent waiting on you counts as busy, so keep doesn't switch off while you read.
- An approved command that runs for 10 seconds or more means the agent is working again, even before its next hook fires, so a closed Mac never sleeps partway through an approved task.
- Settings files are edited safely: an unreadable or invalid file is left alone, an unchanged file isn't rewritten (the app checks at every launch), and permissions are kept. Hooks installed under a custom `CLAUDE_CONFIG_DIR` are found again on upgrade and uninstall.
- `agents uninstall` removes the hooks too.

## 1.1.0

- **Codex and OpenCode count as busy for the whole task**, not only while their own CPU use is high. Before, a Codex or OpenCode session that was waiting on the model or on a long test run looked idle, and Lid Agents could pause partway through. Run `agents integrate` once:
  - **Codex**: switches on Codex's own `prevent_idle_sleep` feature. Codex then holds a sleep assertion while a turn runs, and Lid Agents now counts an agent that holds one as busy. This works in interactive sessions; `codex exec` doesn't take the assertion, so it still relies on CPU use.
  - **OpenCode**: installs a small plugin, `~/.config/opencode/plugins/lid-agents.js`, that holds `caffeinate` while any session is busy, the same signal Claude Code gives.
- **Any terminal or app.** Agents count the same in Ghostty, cmux, Superset, Terminal, iTerm or an IDE's terminal: their wrappers keep the agent's process name. Agents installed through npm, bun or pip, which run as `node` or `python`, now count too, by their script name (before, Gemini CLI and an npm-installed Claude Code were never seen). `agents integrate` switches Codex on in every Codex home it finds, including Superset's Codex account, and OpenCode loads the plugin next to the ones Superset and cmux add.
- **The cup is the last thing a full menu bar hides.** It now asks for a spot next to the clock instead of the left end, which on a notched MacBook is behind the notch. ⌘-drag it anywhere and that place sticks.
- **`agents hotkey ctrl+opt+cmd+l`** changes the hotkey from a terminal (or `none`); the running app picks it up within seconds. If another app already has the hotkey at launch, you're told instead of it silently doing nothing.
- `agents` status shows the hotkey, whether the app is running, and when notifications are off (so switching shows no banner).
- **Fixed:** the menu's **Busy agents** list left out the folder for agents that were busy through `caffeinate`.
- `agents uninstall` also removes the OpenCode plugin.
- **Child processes count.** An agent's CPU now includes everything it started, so a long test suite or build keeps it busy for every agent, including `codex exec`, Gemini CLI and Aider, with no setup.
- **Waiting isn't working.** If every busy agent has held its signal for 30 minutes at almost no CPU (usually it's waiting for your approval, or an idle event went missing), Lid Agents pauses instead of keeping a closed Mac awake until the 8-hour cap. Change it with `AGENTS_QUIET_MINUTES`.
- The OpenCode plugin's `caffeinate` expires after 5 minutes unless it's renewed, like Claude Code's, and can no longer stop OpenCode from exiting. Upgrading from the DMG now refreshes it too.
- `agents uninstall` lists every Codex home where `prevent_idle_sleep` is still on, not just the default one.
- If macOS refuses a hotkey, your working one stays and stays saved; the menu shows a hotkey that couldn't be registered at launch as unavailable, and re-running `agents hotkey` with the same keys retries it.
- A menu bar position you ⌘-dragged the cup to before 1.1.0 is kept.
- Agent detection reads full command lines only for `node`/`python`-style processes and skips `pmset` when no agent is running, so the 5-second refresh stays light.

## 1.0.6

- **Download a DMG.** Each release now includes `LidAgents.dmg`: drag Lid Agents into Applications and open it. No terminal needed.
- **Signed and notarized.** The app and the DMG are signed with a Developer ID and notarized by Apple, so macOS opens them without a security warning.
- **Setup inside the app.** On first launch the app finishes its own setup: it asks once for your password to allow `pmset -a disablesleep`, links the `agents` command and turns on Open at Login. Opened straight from the disk image, it offers to move itself into Applications. If you skip the password, **Finish Setup…** stays in the cup's menu.
- The app is now called **Lid Agents.app**. Updates replace it wherever it's installed and remove the old `LidAgents.app`.

## 1.0.5

- **The default hotkey is now ⌃0 (Control + 0)**: two keys, and not used by macOS, shells or Claude Code. If you never picked a hotkey, yours changes from ⌃⌥⌘A to ⌃0 with this update. If you did pick one, it stays. ⌃⌥⌘A is still one click away under the cup → **Hotkey**.

## 1.0.4

- **Choose your hotkey from the menu.** The cup → **Hotkey** offers ⌃⌥⌘A (default), ⌃⌥⌘L, ⌃⌥⌘K, ⌃⇧⌘Space or None, plus **Record New Hotkey…**, a small window where you press the keys you want. The change applies immediately, with no restart. If another app already uses the combination, you're told and the old hotkey stays.

## 1.0.3

- **Fixed:** clicking **Update to x.y.z** installed the new version but left the old one running, still showing "Updating…". The installer now quits the running app, even when that app is what started it, before replacing it.

## 1.0.2

- **Update notifications.** Once a day the app checks for a newer release. If there is one, you get one notification, and **Update to x.y.z** appears in the cup's menu; one click installs it and reopens the app. It never updates without your click. **Check for Updates…** is also in the menu, and `agents update` does the same in a terminal. Turn the check off with `defaults write io.github.liam-machine.lid-agents CheckForUpdates -bool false`.
- The menu shows the installed version.
- Every merge to `main` now ships as the next patch release automatically.

## 1.0.1

- Holding the hotkey a little too long no longer switches twice: presses are ignored while a switch is still being applied.

## 1.0.0

First release.

- **Menu bar app**: a coffee cup that fills in (with the number of busy agents) while closing the lid keeps agents running. Click it to switch, see which agents are busy, open the log, or turn off Open at Login.
- **Global hotkey** ⌃⌥⌘A to switch, configurable with `defaults write io.github.liam-machine.lid-agents Hotkey "ctrl+opt+cmd+l"`. No Accessibility permission needed.
- **Agent-aware by default**: stays awake only while an agent is busy (Claude Code's own `caffeinate`, or CPU use for Codex, Gemini CLI, Aider, opencode, Amp, Goose, Cursor Agent, Droid), then pauses again after 3 idle minutes and puts a closed Mac to sleep.
- **Safety limits**: an 8-hour cap and a 15% battery floor, both adjustable.
- **`agents` command** for the terminal: `keep`, `pause`, `toggle`, `busy`, status, `uninstall`.
- **One-line installer** that asks for your password once, for a sudoers rule allowing only `pmset -a disablesleep 0|1`.

Install:

```bash
curl -fsSL https://github.com/liam-machine/lid-agents/releases/latest/download/install.sh | bash
```
