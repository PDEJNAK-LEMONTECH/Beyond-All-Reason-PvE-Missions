# Playing the PvE missions together (host + friend)

This is the **shared, tracked** guide for running our modified BAR — the scripted-PvE Mission
API — as a 2-human-vs-AI match over the internet or LAN. It lives in the repo so both of you
get it on clone. (Host-/IP-specific scratch notes stay in the untracked `MULTIPLAYER_HOST.md`.)

The game content lives on your **fork**:

```
https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions
branch: pve-missions      <- the tested mod AND the default branch. (master just tracks upstream.)
```

Both players need a normal **vanilla BAR install** (for the Recoil engine + maps). We only add
this repo as an extra "dev game" beside it. No engine build, no second download of the engine.

---

## 0. The one rule that controls everything: SYNC

Recoil runs the **synced** Lua (gadgets, unit defs, the Mission API) on every machine and
cross-checks the game archive. If the host's and the friend's copies differ, the friend
**can't join** / the match **desyncs**. So:

> **Both machines must be a _clean_ clone of the fork, checked out to the _same commit_ of
> `pve-missions`, with the submodule updated — and nothing extra added inside that folder.**

"Nothing extra" matters: a directory game archive includes *every* file under it. Generated or
local files that exist on one machine but not the other (e.g. the scenario-designer's regenerated
`icons/`, `maps/`, `data.js`, or stray scratch files) can change the archive and break the join.
**Do not run `prepare_assets.ps1` inside the folder you use for multiplayer**, and don't drop
loose files in it. (See §6 if you want to keep developing in the same checkout.)

Verify both machines match before playing:

```bash
git -C <the .sdd folder> rev-parse HEAD          # must be IDENTICAL on both
git -C <the .sdd folder> submodule status        # must be IDENTICAL on both
git -C <the .sdd folder> status --porcelain      # must be EMPTY on both (no extra/changed files)
```

Line endings are already handled: `.gitattributes` forces `*.lua/*.txt/*.tdf` to **CRLF** on
every platform, so a Windows clone and a Linux clone produce byte-identical files. Don't fight it.

---

## 1. Friend's one-time setup (Windows)

Your friend already has vanilla BAR, so the engine + maps are present at:

```
%LOCALAPPDATA%\Programs\Beyond-All-Reason\            <- install root
%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\       <- data dir (engine\, maps\, games\)
```

**The relative location you tell your friend** (relative to the BAR install / engine) is:

```
data\games\BAR-PvE-Missions.sdd
```

i.e. the clone goes inside the engine's `data\games\` folder, in any folder name **ending in
`.sdd`**. (The folder name is cosmetic — the game's real name comes from `modinfo.lua`, so it
will show up as **"Beyond All Reason $VERSION"** regardless of the folder name.)

Steps (PowerShell):

```powershell
# 1. Clone the fork into the engine's games dir, as an .sdd folder.
#    Its default branch is pve-missions (the tested mod), so the clone lands on it.
$games = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\games"
git clone --recurse-submodules `
  https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions.git `
  "$games\BAR-PvE-Missions.sdd"

# 2. Make sure the submodule is at the pinned commit
cd "$games\BAR-PvE-Missions.sdd"
git submodule update --init --recursive

# 3. Enable dev games in the lobby (one empty marker file)
New-Item -ItemType File -Force "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\devmode.txt" | Out-Null
```

> A `git clone` of the whole fork is multi-GB. If that's painful, a shallow clone of just the
> branch works too and is still byte-identical for sync:
> `git clone --depth 1 --branch pve-missions --recurse-submodules <fork-url> "<...>.sdd"`

**Same engine version everywhere.** All machines must launch the *same* engine build. Pick one
folder from `…\data\engine\` (e.g. the newest you both have) and use it on every machine. Tell
your friend the exact version string you're using.

---

## 2. Get the `gametype` string (needed by the start scripts)

The start scripts must name the game archive. For our dev `.sdd` it is **not** a published
version string. To read the exact value, on either machine:

1. Launch the dev game once from the lobby: **Settings → Developer → Singleplayer →
   "Beyond All Reason $VERSION"** → start any skirmish.
2. Open `…\Beyond-All-Reason\data\_script.txt` and copy the `gametype = … ;` line.
3. Paste that value into `<DEV_GAMETYPE>` in the start scripts below.

Because both machines are on the same commit, both report the same `gametype`.

---

## 3. Choose how to host

You can host from **Windows** (you play and host on one PC) or from **Linux** (a dedicated
server; both of you join as clients). Both use the same two start scripts in
`tools/StartScripts/`:

| File | Role | Edit |
|------|------|------|
| `pve_host.txt`   | authoritative match definition (teams, AI, mission, port) | host machine |
| `pve_client.txt` | minimal "join by IP" script | each joining player |

Team layout baked into `pve_host.txt`: **allyTeam0 = you + your friend** (team0 host, team1
friend), **allyTeam1 = the BARb AI**. Mission = `missions/pve_demo.lua` (change `mission_path`
to play a different scenario; it must exist in both clones — it does, you're on the same commit).

### 3A. Windows direct host (simplest — no Linux needed)

You host **and** play on the same PC.

1. On the host PC, fill in `tools/StartScripts/pve_host.txt`: `<HOST_NAME>`, `<FRIEND_NAME>`,
   `<PORT>` (e.g. `8452`), `<MAP_NAME>` (e.g. `Supreme Crossing V1`), `<DEV_GAMETYPE>`.
   Leave `hostip = 0.0.0.0;` and `ishost = 1;`.
2. **Port-forward UDP `<PORT>`** on your router to this PC, and allow it through Windows Firewall:
   ```powershell
   New-NetFirewallRule -DisplayName "BAR PvE Host" -Direction Inbound -Protocol UDP -LocalPort 8452 -Action Allow
   ```
3. Launch the host straight into the match (no lobby):
   ```powershell
   $eng = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\engine\<VERSION>"
   & "$eng\spring.exe" --write-dir "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data" `
       "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\games\BAR-PvE-Missions.sdd\tools\StartScripts\pve_host.txt"
   ```
4. Your friend fills `pve_client.txt` (`<HOST_IP>` = your **public** IP, `<PORT>`, `<FRIEND_NAME>`)
   and launches the same way pointed at `pve_client.txt` (see §3C for the exact command).

### 3B. Linux dedicated host (you both join as clients)

Use the headless server that ships with the same engine version.

1. On the Linux box, recreate the layout the server needs: the engine binary plus a data dir
   containing `games/BAR-PvE-Missions.sdd` (this fork, same commit + submodule) and the map(s)
   you'll use. Point the engine at it with `SPRING_DATADIR` or `--write-dir`.
2. Fill in `pve_host.txt` exactly as in 3A (`ishost = 1; hostip = 0.0.0.0;`).
3. Open the port:
   ```bash
   sudo ufw allow 8452/udp
   ```
   …and port-forward UDP `8452` on the router to the Linux box.
4. Start the dedicated server:
   ```bash
   ./spring-dedicated /absolute/path/to/BAR-PvE-Missions.sdd/tools/StartScripts/pve_host.txt
   ```
5. **Both** you and your friend join as clients (§3C) pointed at the Linux box's public IP.

> The dedicated server itself is not a player; it just relays. The two player slots in
> `pve_host.txt` (`<HOST_NAME>`, `<FRIEND_NAME>`) are filled when you each connect — your
> `MyPlayerName` in `pve_client.txt` must match one of those names.

### 3C. Joining as a client (friend, and also you in the dedicated case)

Fill `tools/StartScripts/pve_client.txt`, then:

```powershell
$eng = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\engine\<VERSION>"
& "$eng\spring.exe" --write-dir "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data" `
    "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\games\BAR-PvE-Missions.sdd\tools\StartScripts\pve_client.txt"
```

(Linux client: same idea with `spring` and the matching data dir.)

---

## 4. Quick LAN test first (recommended before going public)

Before dealing with routers, prove the scripts + sync on your LAN:

1. Host PC: run §3A but set `<HOST_IP>`/connection to your **LAN** IP; keep `ishost = 1`.
2. Second PC (same LAN, same commit, same engine): join with `pve_client.txt` using the host's
   **LAN** IP.
3. Confirm: no "desync"/"missing content" warning, you both land on allyTeam 0, the BARb AI is on
   allyTeam 1, and `[Mission API]` lines appear in `data\infolog.txt`.

---

## 5. Keeping in sync after changes

Whenever the mod changes, the host pushes and the friend pulls the **same commit**:

```bash
# host, after editing + testing:
git add -A && git commit -m "..." && git push fork pve-missions

# friend:
git -C <the .sdd folder> pull
git -C <the .sdd folder> submodule update --init --recursive

# both: confirm identical
git -C <the .sdd folder> rev-parse HEAD
```

`fork` is the remote pointing at `…/Beyond-All-Reason-PvE-Missions.git`. **Never push to
`origin`** — that's upstream `beyond-all-reason/Beyond-All-Reason`, which we don't own.

---

## 6. Note for the host who also develops here

This repo doubles as the dev checkout (live via the `data\games\BAR.sdd` junction). That dev
copy accumulates **untracked/generated files** (the designer's `icons/`, `maps/`, `data.js`,
`DEV_LOCAL.md`, `PLAY_DEMO.bat`, scratch `.lua` at the repo root, …). Those make its archive
differ from your friend's clean clone, which can block the join.

For multiplayer, host from a **clean clone** instead of your dev copy:

```powershell
# a second, clean checkout used only for multiplayer sessions
git clone --branch pve-missions --recurse-submodules `
  https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions.git `
  "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\games\BAR-PvE-Missions.sdd"
```

Keep developing in `C:\PROJ\BAR` (the `BAR.sdd` junction); host/play from
`BAR-PvE-Missions.sdd`. Both show as the same game ("Beyond All Reason $VERSION") — pick the
clean one in the lobby / point the start scripts at it for multiplayer.

---

## 7. Troubleshooting

- **Friend can't connect at all:** UDP `<PORT>` not port-forwarded / blocked by firewall, or wrong
  public IP. Test the LAN path (§4) first to isolate networking from content.
- **"Desync" or "you are running a different version":** archives differ. Re-check §0 — same
  `HEAD`, same submodule, `git status` empty on both, hosting from a clean clone (§6).
- **Dev game not in the lobby list:** `devmode.txt` missing, or the `.sdd` folder's
  `modinfo.lua` doesn't resolve (bad clone path).
- **Match starts but no `[Mission API]` lines:** `mission_path` modoption empty or wrong — it must
  be a path under `singleplayer/`, e.g. `missions/pve_demo.lua`. Check `data\infolog.txt`.
- **Wrong spawn positions:** see the start-position notes in `CLAUDE.md` / `MISSION_API.md`.
```
