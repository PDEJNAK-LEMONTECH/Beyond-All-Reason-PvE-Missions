# tools/multiplayer — host a PvE scenario for a friend (Windows direct host)

Two pieces: a **GUI launcher you run** to host, and a **single Markdown file you send your friend**
that their coding agent uses to set up the join side. For the full background and the manual
(no-GUI) path, see the repo-root `MULTIPLAYER.md`.

| File | Who | What |
|------|-----|------|
| `host_launcher.cmd` | **you** | Double-click. Wrapper that runs `host_launcher.ps1` under `-ExecutionPolicy Bypass` (this PC's policy is Restricted). |
| `host_launcher.ps1` | you | The host GUI (below). |
| `FRIEND_AGENT_SETUP.md` | **your friend's agent** | Send this one file to your friend. Their coding agent (Gemini/Claude/whatever) follows it to clone the fork, match the engine, fetch the map, and build a one-command `join.cmd`. |

## The host GUI (`host_launcher.cmd`)

1. **Create / Sync clone** — first run clones the fork into
   `…\Beyond-All-Reason\data\games\BAR-PvE-Missions.sdd` (a *clean* clone, separate from your dev
   junction `BAR.sdd`) and writes `devmode.txt`. Later runs `git pull` + submodule update. You host
   from this clean clone so untracked dev files never break your friend's join.
2. **Scenario** — auto-discovered from the clone's `singleplayer/missions/*.lua`. Each scenario's
   **map** and **AI count** are read from its embedded `SCENARIO_DESIGNER_V1` block, so the match is
   wired up automatically. (Map-agnostic scenarios like `pve_demo` let you pick any installed map.)
3. **Names / port / difficulty / elimination** — your name, your friend's exact in-game name (must
   match what their `join.cmd` uses), UDP port (default 8452), difficulty, and `deathmode`
   (default `own_com` = a player/AI is out when its own commander dies).
4. **Prep network** — adds the inbound UDP firewall rule (elevates if needed) and shows your
   **public IP**. You still **port-forward that UDP port on your router** to this PC (can't be
   automated).
5. **Host & Play** — writes a start script to `…\data\pve_host_session.txt` (kept **outside** the
   `.sdd` so it never changes the synced archive), then launches `spring.exe` straight into the
   match. `gametype` is read from the clone's `modinfo.lua` (`Beyond All Reason $VERSION`).

Then tell your friend your **public IP + port + their name**; they run `join.cmd <ip> <port>`.

## Authoring → playing a new scenario (the sync loop)

Scenarios are **synced** — your friend must have the exact same file. Workflow:

```
# in your dev checkout C:\PROJ\BAR (author with the scenario designer):
git add -A && git commit -m "new scenario"
git push fork pve-missions          # run this yourself (Git Credential Manager prompts)

# in the host GUI: "Create / Sync clone" pulls it into the clean clone, then it appears in the list.
# your friend: git pull + submodule update (his agent's §8) so he has it too.
```

## Notes / gotchas
- **Stock maps only** for now — your friend's agent auto-downloads stock maps by name with
  `pr-downloader`. A custom map (e.g. a `map_extender` output) isn't on BAR's CDN; you'd have to send
  him the `.sd7` and he drops it in `data\maps\`.
- **Co-op start positions:** both humans share allyTeam 0. If a scenario defines a single human start,
  the Mission API moves both commanders there on frame 1 — just split them apart in-game, or author
  distinct human positions.
- **Never** run `prepare_assets.ps1` or drop loose files inside `BAR-PvE-Missions.sdd` — it changes
  the archive and breaks the join.
