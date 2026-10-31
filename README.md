# devc — per-project terminal command center (WSL + Windows Terminal)

One `devc start` per project opens a dedicated Windows Terminal window with all
dev processes as live tiled panes — backend, frontend, N workers, git/scratch
shells — plus a `ctl` master pane to manage them. Sessions run on a private
tmux server, so they survive closing the window: reattach from anywhere
(including an IDE terminal) with `devc attach`.

## Install

```sh
ln -sf ~/SoftDev/TER/devc ~/.local/bin/devc   # already done
```

## Per-project setup

```sh
cd ~/SoftDev/MyProject
devc init      # writes .devc — edit it
devc start     # pops the project's Windows Terminal window
```

`.devc` — one pane per line:

```
# name: command        (runs from the project root via interactive zsh)
backend: cd backend && pipenv run uvicorn app.main:app --reload
frontend: cd frontend && npm run dev
worker*2: pipenv run python worker.py
```

The auto-added `ctl` master pane doubles as the general-use shell (git etc.);
add more shells anytime with `devc add <name>` (a bare `shell: zsh` line also
works if you want one permanently).

- `name*N:` → N panes `name-1..name-N`, each with `$DEVC_INSTANCE` set.
- A command that is just a shell (`zsh`) gives an interactive pane.
- Every pane gets `$DEVC_PROJECT`, `$DEVC_ROOT`, `$DEVC_PANE`.
- Config changes apply on `devc stop && devc start`.

## Automatic ports

```
ports: BACKEND_PORT=8000 FRONTEND_PORT=5173
backend: uvicorn app:app --reload --port $BACKEND_PORT
frontend: npm run dev -- --port $FRONTEND_PORT
```

At start devc picks the first free port ≥ base for each var (8000, 8001, …)
and exports the **same** values to every pane — services, workers, and your
shells all agree on `$BACKEND_PORT`, so proxies point at the right backend.
Picked ports show at start and in `devc status`; `devc restart` keeps them,
`devc stop && devc start` re-picks. Ad hoc: `devc port 8000` prints the next
free port. Ports are checked, not reserved — a rare race with another process
grabbing it between check and bind just means restarting that pane.

## Commands

| Command | Does |
|---|---|
| `devc start [-w N] [--here] [-d]` | Start + open the WT window (`-w N` worker count, `--here` attach in this terminal, `-d` detached) |
| `devc attach [project]` | Attach in the current terminal (e.g. inside the IDE) |
| `devc stop [project]` | Stop the project's session |
| `devc status` | All running projects, their panes, dead processes |
| `devc restart <name>` | Respawn one pane's command in place |
| `devc scale <name> N` | Set instance count live (add/remove panes) |
| `devc add <name> [-t pane] [-h\|-v] [-l size] [command]` | New pane at runtime (default: a zsh shell under `ctl`) |
| `devc logs <name> [-f]` | Page (or follow) a pane's log file |

All of these work from the `ctl` pane inside the window — it is the command
center's command line. Logs mirror to `~/.devc/logs/<project>/<pane>.log`.

## Using the window

- **Layout**: `ctl` top-left, `frontend` next to it, `backend` as the
  full-height right column, workers and everything else across the bottom.
  `scale`/`add` split existing cells (new shells land under `ctl`). Place one
  elsewhere by naming the pane to split: `devc add db -t backend -h -l 30%`
  (beside `backend`, 30% wide), `-v` for below. To rearrange after the fact,
  drag the borders, or use tmux directly on the devc socket
  (`tmux -L devc list-panes -t "=devc-<proj>:0" -F '#{pane_id} #{@devc_name}'`
  for the ids, then `move-pane -s %12 -t %3 -h`).
- **Every pane is a real terminal**: the command is typed into a live zsh, so
  `Ctrl-C` stops it and leaves you at a prompt — rerun with `↑ Enter` (it's in
  the shell history), or let `devc restart <name>` do Ctrl-C + rerun for you.
  A crash also lands at the prompt with the output still on screen.
- Pane titles are color-coded by the dot and background tint: **blue ●**
  services, **green ●** workers, **gray ●** shells; **red ✖** appears only if
  the pane's shell itself exits (`devc restart` revives it).
- **Click** a pane to focus it, **wheel** to scroll its history (q to exit scroll).
- tmux extras (prefix `Ctrl-b`): `z` zoom a pane full-window, `d` detach.
- Closing the window detaches; everything keeps running (`devc status`).

## Caveats

- If **every** WSL process ends (all terminals and the IDE closed), Windows may
  stop the WSL VM after a short idle, which kills the sessions. Keeping any
  WSL window open prevents it.
- Project identity = directory basename; keep project dir names space-free.
- Runs on a dedicated tmux socket (`tmux -L devc …`) — your normal tmux, if
  any, is untouched.

## Test

```sh
./test_devc.sh   # headless end-to-end smoke test
```
