# FilesWatcher

Automatic, git-based backups for the folders of any Windows program (games, editors, tools...).
It watches the folders you choose, commits every change to a local git repo and pushes it to a remote
(GitHub, GitLab, Azure DevOps...). It starts the real program for you, stops when the program exits, and can
**restore or sync** your data on another machine using the git remote as the intermediary.

Built with PowerShell + git only. No installation, no dependencies besides git.

## Features

- Watches one or several folders per program (any change: create, edit, rename, delete, subfolders...).
- Waits for a quiet period (`debounceSeconds`) before committing, so bursts of changes become one commit.
- Launches the real program and does a final backup when it exits.
- One independent git repo per program, stored in `backup\<alias>\.git`. Your files are never copied.
- Works fully offline (no remote) or with any git remote.
- Files over the host limit (GitHub: 100 MB) are automatically split into `.partNNN` chunks and joined back on restore.
- A manifest stored in the repo makes restoring possible with just the remote URL.
- Sync between machines: the remote overwrites the local state of an alias.
- GUI launcher: add programs, run them, create desktop shortcuts, restore.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (included in Windows).
- [Git for Windows](https://git-scm.com/download/win) (includes Git Credential Manager for remote logins).

## Files

| File | Purpose |
|---|---|
| `Launch.cmd` | Entry point. No argument: opens the menu. With an alias: starts the watcher for it. |
| `Launcher.ps1` | The menu: add a program, run a program / create a desktop shortcut, restore. |
| `Watch-Backup.ps1` | The watcher: launches the program, commits and pushes changes. |
| `Restore-Backup.ps1` | Restores a new alias from a remote URL, or syncs an existing one from its remote. |
| `config.json` | Global settings and the list of programs (created/edited by the launcher). |

Runtime folders created next to the scripts: `backup\<alias>\` (git repos) and `logs\`.

## Quick start: Factorio (saves, mods and scenarios)

Factorio keeps everything under `%APPDATA%\Factorio`:

```
C:\Users\<you>\AppData\Roaming\Factorio\saves
C:\Users\<you>\AppData\Roaming\Factorio\mods
C:\Users\<you>\AppData\Roaming\Factorio\scenarios
```

### 1. Create an empty remote repository

Create an empty **private** repository (for example `factorio-backup`) on GitHub and copy its URL,
e.g. `https://github.com/<user>/factorio-backup.git`. Do not add a README or .gitignore.

### 2. Add the program

1. Double-click `Launch.cmd` and choose **Add a program to watch**.
2. Fill in the form:
   - **Alias**: `factorio`
   - **Git remote URL**: `https://github.com/<user>/factorio-backup.git` (leave empty for local-only backups)
   - **Branch**: `main`
   - **Program .exe**: the real game, e.g.
     `C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe`
   - **Folders to watch**: press **+** three times and pick the `saves`, `mods` and `scenarios` folders listed above.
3. Click **Add**. The entry is written to `config.json`:

```json
{
  "alias": "factorio",
  "watchPaths": [
    "C:\\Users\\<you>\\AppData\\Roaming\\Factorio\\saves",
    "C:\\Users\\<you>\\AppData\\Roaming\\Factorio\\mods",
    "C:\\Users\\<you>\\AppData\\Roaming\\Factorio\\scenarios"
  ],
  "remoteUrl": "https://github.com/<user>/factorio-backup.git",
  "branch": "main",
  "programPath": "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Factorio\\bin\\x64\\factorio.exe",
  "programArgs": ""
}
```

> **You manage the remote and its credentials.** The tool never creates the remote repo or stores tokens. The
> remote must exist and you must be logged in (Git Credential Manager login, token or SSH key). If the remote is
> unreachable or the push fails, the watcher shows a dialog (Exit / Retry / Continue locally) with the exact git
> commands to run by hand in `backup\factorio` (`add -A`, `commit -m init`, `push -u origin main`); after logging
> in once, press **Retry**.

### 3. Create the desktop shortcut

1. `Launch.cmd` -> **Run a program** -> select `factorio` -> **Create desktop shortcut**.
2. A `factorio.lnk` appears on your desktop, using the game's icon. Use it instead of the original shortcut:
   it starts the watcher and the game together, and the watcher takes a final backup when the game closes.

(**Launch now** starts it once without creating a shortcut.)

### 4. First run

The first run commits everything (the initial `git add` can take a few minutes with many saves; the game starts
before it). If the remote needs authentication, a dialog tells you the exact commands to log in once, then press
**Retry**. After the log line `Push OK` (set `"logLevel": "info"` to see it) nothing is pending; the watcher keeps
running until the game exits.

### 5. Restore on another machine (or after a reinstall)

1. Copy this folder to the new machine (or clone your public copy of it) and install git.
2. `Launch.cmd` -> **Restore / sync from a remote** -> **New, from a git remote URL**.
3. Paste the remote URL. Optionally choose another folder (if the original path does not exist there) and alias.
4. The tool downloads the repo, recreates the folders, joins any split big files, and adds the entry to `config.json`.
5. Fix `programPath` in `config.json` if the game lives elsewhere, then create the desktop shortcut as in step 3.

### 6. Keep two machines in sync

Machine A runs the watcher while you play, so every change reaches the remote. On machine B:
`Launch.cmd` -> **Restore / sync from a remote** -> pick the existing alias `factorio`.
The remote **overwrites** the local state of that alias (watched folders, `backup\factorio` repo and its
`config.json` entry). A confirmation is shown first. Local `programPath`, `programArgs` and `remoteUrl`
are kept. Close the game and the watcher on B before syncing, and do not play on both machines at the same time.

## Command line

```bat
Launch.cmd                      :: menu
Launch.cmd factorio             :: watch + launch the alias (what the shortcut does)
```

```powershell
.\Watch-Backup.ps1 -Alias factorio -Once       # a single backup and exit
.\Restore-Backup.ps1                           # restore form
.\Restore-Backup.ps1 -Remote <url>             # restore without the form
.\Restore-Backup.ps1 -Remote <url> -Root D:\Games\Factorio -Alias factorio2
```

## config.json reference

Global settings (can be overridden per program):

| Key | Default | Description |
|---|---|---|
| `logLevel` | `error` | `error` logs only problems; `info` logs everything (events, commits, push). |
| `debounceSeconds` | `3` | Quiet time without changes before a commit is made. |
| `maxFileSizeMB` | `95` | Size limit per file. Keep it below your host's limit (GitHub: 100 MB). `0` disables the check. |
| `splitLargeFiles` | `true` | Split files over the limit into `.partNNN` chunks. If `false`, they are skipped with an error in the log. |

Per program (`programs` array):

| Key | Description |
|---|---|
| `alias` | Unique name (`A-Z a-z 0-9 . _ -`). Names the repo folder `backup\<alias>` and the log. |
| `watchPaths` | Folders to watch. They must be on the same drive; their common parent becomes the repo work tree. |
| `remoteUrl` | Git remote. Empty = local-only backup. |
| `branch` | Branch to commit to (default `main`). |
| `programPath` / `programArgs` | Program to start together with the watcher. Empty = only watch. |

Logs are in `logs\<alias>.log` (and `logs\_general.log` before the alias is resolved).

## How it works

- `backup\<alias>\.git` uses the common parent of `watchPaths` as its work tree and a whitelist in
  `info/exclude`, so only the watched folders are versioned and nothing is copied.
- Files over `maxFileSizeMB` are copied to a temporary `parts_<timestamp>` folder, split, committed in order
  (FIFO) and the temporary folder is deleted. Restoring joins the parts back into the original file.
- `.filesbackup/config.json` and `.filesbackup/README.md` inside the repo describe the program (alias, folders,
  program path...) so a restore needs only the URL. `remoteUrl` is deliberately not stored there.
- File changes are detected with `FileSystemWatcher` (no polling).

## Notes and limitations

- Credentials are handled by Git Credential Manager; nothing is stored in this tool. Never put tokens in `remoteUrl`.
- Launchers like Steam may start the game through another process; if the watcher exits immediately, point
  `programPath` to the game's real `.exe`.
- Restoring/syncing does not delete local files that git never tracked.
- GitHub also limits repository size; consider a private repo and occasional history cleanup for very large saves.

## License

Add the license of your choice (for example MIT) before publishing.