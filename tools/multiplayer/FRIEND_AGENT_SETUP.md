# Set up "Beyond All Reason — PvE Missions" to join a friend's match

> **You are a coding agent** (Gemini, Antigravity, Claude Code, Copilot — whichever the user runs).
> Your human teammate wants to join a **private modded Beyond All Reason (BAR)** PvE match that a
> friend is hosting. Do everything below **autonomously** on a Windows PC, then hand the human back
> a **single command** they run at game time. Read the whole file first; it is self-contained.

---

## 0. What this is (context you need)

- Your human already has **vanilla BAR** installed (the Recoil engine + maps + the Chobby lobby).
- The friend ("the host") runs a **private fork** that adds a scripted-PvE "Mission API". You will add
  that fork **beside** the vanilla install as an extra local game — **no engine rebuild, no second
  engine download** (you reuse the installed engine).
- You **cannot** join this through the normal BAR lobby: the official lobby only serves the *published*
  game. This mod is hosted **directly by IP** (the host runs the match; your human connects with a
  small join script you create here).

### The one rule that matters: SYNC
Recoil runs **synced** Lua on every machine and cross-checks the game archive. If your copy differs
from the host's **by a single byte**, the join fails / desyncs. Therefore:

> Clone the fork **clean**, check out the **same commit** the host is on, update the submodule, and
> **add nothing** inside that folder. Don't generate files in it, don't run asset scripts in it.

Line endings are already handled (the repo forces CRLF via `.gitattributes`), so a Windows clone is
byte-identical to the host's.

**The repo:**
```
URL:    https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions.git
Branch: pve-missions          (this is the DEFAULT branch and holds the tested mod)
```

---

## 1. Locate the install + prerequisites

```powershell
# BAR install + data dir (standard location)
$Bar  = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason"
$Data = "$Bar\data"
Test-Path $Data            # must be True. If False, ask the human where BAR is installed.

# git must exist
git --version              # if missing, install Git for Windows first
```

If `$Data` doesn't exist, BAR may be installed elsewhere (e.g. a Steam/standalone path) — ask the
human for the folder that contains `engine\`, `maps\`, and `games\`, and use that as `$Data`.

---

## 2. Clone the fork as a local "dev game"

The clone goes inside the engine's `data\games\` folder, in a folder name **ending in `.sdd`**.

```powershell
$Games = "$Data\games"
$Sdd   = "$Games\BAR-PvE-Missions.sdd"

git clone --branch pve-missions --recurse-submodules `
  https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions.git `
  "$Sdd"

cd "$Sdd"
git submodule update --init --recursive

# Enable dev games in the lobby (one empty marker file)
New-Item -ItemType File -Force "$Bar\devmode.txt" | Out-Null
```

> The full clone is multi-GB. A shallow clone is byte-identical for sync and faster:
> `git clone --depth 1 --branch pve-missions --recurse-submodules <url> "$Sdd"`

The game's real name comes from `modinfo.lua`, so it shows up as **"Beyond All Reason $VERSION"**
regardless of the folder name. (The folder name is cosmetic.)

---

## 3. Match the engine version

All machines must launch the **same** engine build. The host will tell your human the exact version
string (e.g. `recoil_2025.06.24`). Check whether it's present, and fetch it if not:

```powershell
$Engine = "recoil_2025.06.24"   # <-- replace with the version the host gives you
Test-Path "$Data\engine\$Engine\spring.exe"   # True => you already have it

# If missing, download it with the engine's own downloader (pr-downloader ships with any engine):
$prd = Get-ChildItem "$Data\engine\*\pr-downloader.exe" | Select-Object -First 1
& $prd.FullName --filesystem-writepath "$Data" --download-engine $Engine
```

---

## 4. Pre-download the maps (so any scenario the host picks just works)

Maps are **not** part of the synced game archive — they're separate files. The host chooses the
scenario (and therefore the map) at launch. Pre-fetch every map the bundled scenarios use, plus
whatever map the host announces, so your human is never caught missing one. Stock BAR maps download
by name:

```powershell
$prd = Get-ChildItem "$Data\engine\*\pr-downloader.exe" | Select-Object -First 1

# Parse the map name out of every scenario in the clone and download the ones you don't have.
Get-ChildItem "$Sdd\singleplayer\missions\*.lua" | ForEach-Object {
    $t = Get-Content -Raw $_.FullName
    $m = [regex]::Match($t, '(?s)SCENARIO_DESIGNER_V1\s*(\{.*?\})\s*\]==\]')
    if ($m.Success) {
        $b = $m.Groups[1].Value | ConvertFrom-Json
        if ($b.map -and $b.map.name) {
            $file = $b.map.file
            if (-not (Test-Path "$Data\maps\$file")) {
                Write-Host "Downloading map: $($b.map.name)"
                & $prd.FullName --filesystem-writepath "$Data" --download-map "$($b.map.name)"
            }
        }
    }
}
```

If the host names a specific map your human doesn't have yet, fetch it directly:
```powershell
& $prd.FullName --filesystem-writepath "$Data" --download-map "Supreme Crossing V1"   # example
```

> If a `--download-map` by name fails, the map can also be downloaded by opening BAR's lobby once and
> selecting that map in a skirmish — then it's cached for the direct-join too.

---

## 5. Create the one-command join script

Ask the human for the **exact in-game name** they'll use. **It must match the name the host typed for
them** in the host launcher (the host seats players by name). Then write these two files **outside the
`.sdd`** (e.g. in the data dir), so they never affect sync:

**`join.ps1`** — generates the connection script and launches the game:
```powershell
# join.ps1 -- run as: powershell -ExecutionPolicy Bypass -File join.ps1 <HOST_IP> [PORT]
param(
  [Parameter(Mandatory=$true)][string]$HostIP,
  [int]$Port = 8452
)
$Bar    = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason"
$Data   = "$Bar\data"
$Engine = "recoil_2025.06.24"          # <-- same version as the host
$Name   = "REPLACE_WITH_YOUR_INGAME_NAME"   # <-- must match what the host typed for you

$spring = "$Data\engine\$Engine\spring.exe"
$script = "$Data\pve_client_session.txt"

@"
[GAME]
{
    HostIP       = $HostIP;
    HostPort     = $Port;
    MyPlayerName = $Name;
    IsHost       = 0;
}
"@ | Set-Content -LiteralPath $script -Encoding ASCII

& $spring --write-dir "$Data" "$script"
```

**`join.cmd`** — double-clickable wrapper (handles the Restricted execution policy):
```bat
@echo off
REM Usage: join.cmd <HOST_IP> [PORT]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0join.ps1" %*
echo.
echo === BAR closed. Press any key. ===
pause >nul
```

Fill in `$Name` (the agreed in-game name) and `$Engine` (the host's version) in `join.ps1` before
finishing. Put both files somewhere convenient for the human (Desktop is fine — they're outside the
`.sdd`).

---

## 6. Verify sync (do this before the session)

The host will tell your human the commit hash they're on. Confirm a clean, matching checkout:

```powershell
cd "$Sdd"
git rev-parse HEAD          # must EQUAL the host's commit hash
git submodule status        # must match the host
git status --porcelain      # must be EMPTY (no extra/changed files)
```

If `git status` is not empty, you added something to the `.sdd` — remove it (or re-clone clean).

---

## 7. Game time — what the human does

1. The host starts the match and reads out their **public IP**, the **UDP port**, and confirms the
   **player name**.
2. The human runs:
   ```
   join.cmd <HOST_IP> <PORT>
   ```
   (e.g. `join.cmd 203.0.113.7 8452`). BAR launches straight into the match.

That's it. Your human lands on **allyTeam 0** next to the host; the BARb AI is on **allyTeam 1**; the
scripted events (AI un-freezing, barriers exploding, units spawning) fire as the match progresses.

---

## 8. Keeping current (when the host changes a scenario)

Scenarios live **inside** the synced game archive, so the friend **must have the scenario file too** —
it is not server-side. It arrives automatically with the clone. Whenever the host adds or edits a
scenario, they push it and your human pulls the **same commit**:

```powershell
cd "$Sdd"
git pull
git submodule update --init --recursive
git rev-parse HEAD          # confirm it matches the host again
```

(Only re-run the map download in §4 if a new scenario uses a map you don't have yet.)

---

## 9. Success criteria & troubleshooting

**Looks right when:** no "desync"/"different version" warning at join; both humans on allyTeam 0; the
BARb AI on allyTeam 1; and `data\infolog.txt` shows `[Mission API]` lines once the match starts.

| Symptom | Fix |
|---|---|
| "You are running a different version" / desync at join | Archives differ. Re-check §6 — same `HEAD`, same submodule, `git status` empty. Re-clone clean if unsure. |
| Can't connect at all | Wrong public IP, or the host hasn't port-forwarded / firewalled the UDP port. Have the host re-confirm IP + that the port is open. Try again. |
| "Map not found" at launch | The host's chosen map isn't downloaded — fetch it (§4) by the name the host gives. |
| Game starts but no `[Mission API]` lines | Host issue (their `mission_path` modoption) — not your side. |
| Engine mismatch | Make sure `$Engine` in `join.ps1` is the exact version string the host uses, and that you downloaded it (§3). |

---

### Quick checklist for you (the agent)
- [ ] Cloned fork → `data\games\BAR-PvE-Missions.sdd` on branch `pve-missions`, submodule updated, `devmode.txt` created.
- [ ] Engine version matches the host (downloaded if needed).
- [ ] Maps pre-downloaded.
- [ ] `join.ps1` + `join.cmd` written outside the `.sdd`, with the agreed **name** and **engine** filled in.
- [ ] `git status --porcelain` is empty; `HEAD` matches the host.
- [ ] Told the human: run `join.cmd <HOST_IP> <PORT>` when the host says go.
