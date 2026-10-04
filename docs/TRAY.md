# Windows tray

A small tray icon that shows Codex and Claude quota without opening the dashboard.

```
Codex
  5-hour  100% remaining  ·  resets in 4h 59m
  7-day    93% remaining  ·  resets in 5d 20h

Claude
  5-hour   79% remaining  ·  resets in 4h 11m
  7-day    68% remaining  ·  resets in 5d 12h
```

Left-click the icon for this panel (with **Refresh now**, **Open Dashboard**, **Exit**). Right-click shows the same actions as a menu. Hovering shows a one-line summary.

The icon is a colored dot with the lowest remaining percentage: green above 30%, amber 10–30%, red below 10%, gray when nothing is current. There are no notifications or popups.

## How it works

The tray is only a viewer. It reads the tracker's local API (`/api/health`, `/api/overview`) about once a minute and never contacts Codex or Claude itself. The tracker keeps polling on its own schedule. **Refresh now** calls the same `POST /api/refresh` the dashboard uses. Nothing leaves the machine and the tray never reads credentials.

It is plain PowerShell with Windows Forms: no new npm dependency and no changes to the server or dashboard. The files are in `scripts/tray/`.

## Stale data is never shown as current

A window is only shown as a percentage when the provider is connected, the window has not already reset, and the tracker observed it in the last 10 minutes. Otherwise the row says `Stale` or `Unavailable` plus the last valid update time. If the tracker is not running, every row says `Unavailable`.

When the Claude sign-in has expired, the tray adds: *Run Claude CLI once to refresh authentication.* Claude's token lasts about 8 hours and only the terminal `claude` command renews the stored copy, so this appears if you have not used the CLI for a while. The tray never refreshes it for you.

## Start, stop, restart

The existing `AI Usage Tracker` scheduled task now starts the tracker and then the tray at every sign-in. It does not open a browser. There is no second task. If a tray is already running, a new one exits silently.

| Action | How |
|---|---|
| Stop the tray | Tray menu → **Exit** |
| Start/restart both | `Start-ScheduledTask -TaskName "AI Usage Tracker"` (restarts the tracker; starts the tray if it is not running) |
| Start only the tray | `powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File scripts\tray\ai-usage-tray.ps1` |
| Start the tracker without the tray | `scripts\start-ai-usage-tracker.ps1 -NoTray` |
| Print the current view as text | `scripts\tray\ai-usage-tray.ps1 -PrintState` |

Windows 11 may place a new icon in the hidden overflow area. Drag it onto the taskbar once to keep it visible.

**Open Dashboard** opens `http://localhost:<PORT>`, using the `PORT` in `.env` (default 8893).

## Codex discovery

The tracker needs the `codex` executable. The Codex desktop app does not put it on `PATH`, and its folder name changes with each update. At startup `start-ai-usage-tracker.ps1` uses the first of these that runs `--version` successfully:

1. `CODEX_BIN` from the environment or `.env`
2. `codex` on `PATH`
3. `%LOCALAPPDATA%\OpenAI\Codex\bin\<version>\codex.exe` (newest first)

It sets `CODEX_BIN` only for the tracker process; `.env` and `PATH` are not changed. If none works it writes a line to `logs\ai-usage-tracker-error.log` and Codex shows as disconnected.

## Troubleshooting

| Symptom | Check |
|---|---|
| No icon | Look in the hidden-icons overflow. Confirm a `powershell.exe` running `ai-usage-tray.ps1` exists. Errors go to `logs\ai-usage-tray.log`. |
| Everything `Unavailable` | The tracker is not running. Run `Start-ScheduledTask -TaskName "AI Usage Tracker"`. |
| Codex `Unavailable` | `curl http://127.0.0.1:8893/api/health` and read the Codex `error`. See `logs\ai-usage-tracker-error.log` for a "Codex CLI not found" line. |
| Claude `Stale` | Run `claude` once in a terminal, then **Refresh now**. |

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tray\tests.ps1
```

Runs the tray logic against a fake tracker API (needs Node): both providers, one unavailable, stale and expired data, tracker down and back, manual refresh, level thresholds.

## Remove the tray

1. Choose **Exit** from the tray menu.
2. Revert `scripts\start-ai-usage-tracker.ps1` to the upstream version (`git checkout <upstream-branch> -- scripts/start-ai-usage-tracker.ps1`), or just start it with `-NoTray` in the scheduled task's arguments.
3. Delete `scripts\tray\` and this file.

The scheduled task itself is unchanged by the tray, so nothing needs to be unregistered.

## Updating from upstream

The tray adds only new files under `scripts/tray/` and `docs/`. The one upstream file it edits is `scripts/start-ai-usage-tracker.ps1` (Codex discovery and the tray launch at the end), plus one pointer in `README.md`. If upstream changes either, expect a small merge conflict there; keep upstream's changes and re-apply those two blocks. The tray depends on the shape of `GET /api/health` and `GET /api/overview` (`limits.fiveHour` / `limits.sevenDay` with `usedPercent`, `resetsAt`, `observedAt`); `scripts/tray/tests.ps1` encodes that shape, so run it after an update.
