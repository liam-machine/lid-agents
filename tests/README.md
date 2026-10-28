# tests

`run.sh` tests `bin/agents` without depending on what's running on the Mac:

```bash
tests/run.sh          # prints ok/FAIL per check and exits 1 if any fail
```

It runs `bin/agents` with an empty environment and a temporary `HOME`, so your real settings,
needs-input markers and the `pmset` flag are never touched. CI runs it on every push and pull
request.

## What it checks

- **Detection** (`cases/`): which processes `agents busy` reports, and why.
- **`agents mark`**: a pid below an agent marks that agent and records its children at that
  moment; non-agents mark nothing; `working` clears and leaves a stamp; a clear that lands after
  a `mark waiting` started wins the race; it always exits 0.
- **`agents integrate`** hooks: added once however often it runs, an unchanged file not
  rewritten, permissions and other hooks and settings kept, `.lid-agents.bak` backups written,
  a custom `CLAUDE_CONFIG_DIR` recorded, removal restores the original bytes, files that aren't a
  JSON object left alone. A stand-in `codex` on `PATH` answers `codex features`.

## Detection cases

Each directory in `cases/` is one snapshot of a Mac, fed in through `AGENTS_TEST_FIXTURE`:

| File | Stands in for | Format |
|---|---|---|
| `procs` | `ps -axo pid=,ppid=,pcpu=,etime=,comm=` | `pid ppid cpu elapsed command`, elapsed as `ps` prints it (`00:45`, `1-02:00:00`) |
| `args` (optional) | `ps -ww -o pid=,args=` for interpreter processes | `pid argv...` |
| `assertions` (optional) | `pmset -g assertions` | as `pmset` prints it |
| `waiting` (optional) | needs-input markers | `pid [children when marked, comma-separated]` per line |
| `expected` | what `agents busy` should report | `pid name why why`, or `No busy agents` |

Order in `expected` doesn't matter. Use pids above 99999 (the most macOS hands out), so no
fixture pid can be a real process. To add a case, make a directory with these files and run
`tests/run.sh`.
