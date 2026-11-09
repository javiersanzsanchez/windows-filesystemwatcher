<#
.SYNOPSIS
  Watches the folders of a program (identified by its alias in config.json) and, on any change,
  commits to a dedicated git repo (backup\<alias>\.git, no file copies) and pushes if a remote is set.
.EXAMPLE
  .\Watch-Backup.ps1 -Alias factorio          # watch and launch the program of that alias
  .\Watch-Backup.ps1 -Alias factorio -Once    # a single backup, then exit
#>
param(
    [string]$Alias,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
try { $utf8 = New-Object Text.UTF8Encoding $false; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8 } catch {}
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$logLevel = "$($cfg.logLevel)".Trim().ToLower()
if ($logLevel -notin 'error', 'info') { $logLevel = 'error' }
$script:logFile = Join-Path $PSScriptRoot 'logs\_general.log'

# Levels: error = critical only; info = full detail (events, waits, commits, push)
function Log($m, $level = 'info') {
    if ($level -eq 'info' -and $logLevel -ne 'info') { return }
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $level.ToUpper(), $m
    Write-Host $line
    $dir = Split-Path $script:logFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    Add-Content -Path $script:logFile -Value $line -Encoding UTF8
}

# The script runs hidden: errors are shown in a blocking dialog with 3 options
function Show-ErrorChoice($title, $msg) {
    Log "$title - $msg" 'error'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "FilesBackup [$Alias] - $title"
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(560, 300)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'
    $box.Text = "$msg`r`n`r`nLog: $script:logFile" -replace "(?<!\r)\n", "`r`n"
    $box.SetBounds(12, 12, 536, 230)
    $form.Controls.Add($box)

    $form.Tag = 'exit'
    $defs = @(@('Exit', 'exit', 12), @('Retry', 'retry', 218), @('Continue locally', 'local', 318))
    foreach ($d in $defs) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $d[0]; $b.Tag = $d[1]
        $b.SetBounds($d[2], 255, $(if ($d[1] -eq 'local') { 230 } else { 100 }), 30)
        $b.Add_Click({ param($s, $e) $s.FindForm().Tag = $s.Tag; $s.FindForm().Close() })
        $form.Controls.Add($b)
    }
    # With -WindowStyle Hidden the first window would inherit SW_HIDE; force it visible
    Add-Type -Namespace Native -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
    $form.Add_Shown({ [void][Native.Win]::ShowWindow($form.Handle, 5); $form.Activate() })
    [void]$form.ShowDialog()
    return $form.Tag
}

# No interactive prompts: if credentials are missing or expired, git fails instead of hanging
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

# Alias resolution -> program configuration
$programs = @($cfg.programs)
if (-not $Alias -and $programs.Count -eq 1) { $Alias = "$($programs[0].alias)" }
$prog = $programs | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
if (-not $prog) {
    $known = ($programs | ForEach-Object { $_.alias }) -join ', '
    [void](Show-ErrorChoice 'Invalid alias' "Alias '$Alias' not found in $ConfigPath.`nAvailable aliases: $known`nUsage: Launch.cmd <alias>")
    exit 1
}
if ("$Alias" -notmatch '^[\w.-]+$') {
    [void](Show-ErrorChoice 'Invalid alias' "The alias '$Alias' may only contain letters, digits, '.', '_' and '-'.")
    exit 1
}
if (@($programs | Where-Object { $_.alias -eq $Alias }).Count -gt 1) {
    [void](Show-ErrorChoice 'Duplicate alias' "The alias '$Alias' appears more than once in config.json.")
    exit 1
}

$script:logFile = Join-Path $PSScriptRoot "logs\$Alias.log"
# watchPaths (list) or watchPath (single path, backwards compatible)
$watchPaths = @(@($prog.watchPaths) + @($prog.watchPath) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\') } | Select-Object -Unique)
if ($watchPaths.Count -eq 0) {
    [void](Show-ErrorChoice 'Invalid configuration' "The alias '$Alias' has no watchPaths.")
    exit 1
}
# Common directory = work tree of the repo. Everything outside the watched paths is excluded (info/exclude)
$watch = $watchPaths[0]
foreach ($wp in $watchPaths) {
    while ($watch -and -not ($wp -eq $watch -or $wp.StartsWith($watch + '\', [StringComparison]::OrdinalIgnoreCase))) {
        $watch = Split-Path $watch -Parent
    }
}
if (-not $watch) {
    [void](Show-ErrorChoice 'Invalid configuration' "The paths of '$Alias' do not share a common directory (different drives):`n$($watchPaths -join "`n")")
    exit 1
}
$watch = $watch.TrimEnd('\')
$branch      = if ($prog.branch) { "$($prog.branch)" } else { 'main' }
$debounce    = if ($prog.debounceSeconds) { [int]$prog.debounceSeconds } elseif ($cfg.debounceSeconds) { [int]$cfg.debounceSeconds } else { 3 }
$remote      = "$($prog.remoteUrl)".Trim()
$maxFileMB   = if ($null -ne $prog.maxFileSizeMB) { [double]$prog.maxFileSizeMB } elseif ($null -ne $cfg.maxFileSizeMB) { [double]$cfg.maxFileSizeMB } else { 95 }
$splitLarge  = if ($null -ne $prog.splitLargeFiles) { [bool]$prog.splitLargeFiles } elseif ($null -ne $cfg.splitLargeFiles) { [bool]$cfg.splitLargeFiles } else { $true }
$chunkBytes  = [int64]($maxFileMB * 1MB)
$programPath = "$($prog.programPath)".Trim()
$programArgs = "$($prog.programArgs)".Trim()

# The repo lives in backup\<alias>\.git and uses the common directory as its work tree: no files are copied
$backup = Join-Path $PSScriptRoot "backup\$Alias"
$gitDir = Join-Path $backup '.git'
$G = @("--git-dir=$gitDir", "--work-tree=$watch")

# Returns $true if the remote is usable; $false if continuing locally; exits if the user chooses to
function Confirm-Remote {
    while ($true) {
        $out = & git @G ls-remote --heads origin 2>&1
        if ($LASTEXITCODE -eq 0) { Log 'Remote verified: access and credentials OK'; return $true }
        $choice = Show-ErrorChoice 'Remote not reachable' "Could not reach the remote '$remote'. Credentials missing, expired or wrong URL.`nTo authenticate the first time, open a console and run (a login window will appear):`n  cd `"$backup`"`n  git --git-dir=.git add -A`n  git --git-dir=.git commit -m `"init`"`n  git --git-dir=.git push -u origin $branch`nThen click Retry.`n`n$($out -join "`n")"
        if ($choice -eq 'retry') { continue }
        if ($choice -eq 'local') { Log 'Continuing locally (no push) for this session'; $script:remote = ''; return $false }
        Log 'Exit requested by the user'; exit 1
    }
}
$script:pendingPush = $false

function Push-Remote {
    while ($remote) {
        $out = & git @G push -u origin $branch 2>&1
        if ($LASTEXITCODE -eq 0) { Log 'Push OK'; $script:pendingPush = $false; return }
        $script:pendingPush = $true
        $text = $out -join "`n"
        if ($text -match 'non-fast-forward|fetch first|rejected|failed to push some refs') {
            $hint = "The remote has changes that are not in the local repo (conflict). Resolve it by hand in ${backup}:`n  git pull --rebase origin $branch`n  git push`nIf you do not care about the remote and want to overwrite it: git push --force origin $branch"
        } else {
            $hint = "Likely cause: expired credentials or no access. Renew them from a console in ${backup}:`n  git --git-dir=.git push -u origin $branch`n(if this is the first time and there are no commits yet: first git --git-dir=.git add -A and git --git-dir=.git commit -m init)"
        }
        $choice = Show-ErrorChoice 'Push failed' "Could not push. The commits are already saved locally.`n`n$hint`n`nGit output:`n$text"
        if ($choice -eq 'retry') { continue }
        if ($choice -eq 'local') { Log 'Continuing locally (no push) for this session'; $script:remote = ''; return }
        Log 'Exit requested by the user'; exit 1
    }
}

function Invoke-Git {
    $out = & git @G @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" }
    $out
}

# Regenerates .git\info\exclude: ignores everything except the watched paths (level-by-level whitelist)
function Update-Exclude($bigRels = @(), [switch]$Quiet) {
    $rules = New-Object System.Collections.Generic.List[string]
    $rules.Add('# Generated by Watch-Backup.ps1: do not edit')
    if ($watchPaths -notcontains $watch) {
        $seen = @{}
        $rules.Add('/*')
        foreach ($wp in $watchPaths) {
            $parts = $wp.Substring($watch.Length).Trim('\') -split '\\'
            $prefix = ''
            for ($i = 0; $i -lt $parts.Count; $i++) {
                $prefix += '/' + $parts[$i]
                $key = $prefix.ToLower()
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $rules.Add("!$prefix/") }
                if ($i -lt $parts.Count - 1) { $star = "$prefix/*"; if (-not $seen.ContainsKey($star.ToLower())) { $seen[$star.ToLower()] = $true; $rules.Add($star) } }
            }
        }
    }
    # Big files are excluded so git neither reads them nor stores them as an object on every cycle
    foreach ($b in $bigRels) { $rules.Add('/' + ($b -replace '([\[\]\*\?])', '\$1')) }
    $infoDir = Join-Path $gitDir 'info'
    if (-not (Test-Path $infoDir)) { New-Item -ItemType Directory $infoDir | Out-Null }
    [IO.File]::WriteAllLines((Join-Path $infoDir 'exclude'), $rules)
    if (-not $Quiet) { Log "Exclusion rules: $($rules -join ' | ')" }
}

function Initialize-Repo {
    foreach ($wp in $watchPaths) { if (-not (Test-Path $wp)) { throw "Watched path does not exist: $wp" } }
    if (-not (Test-Path $gitDir)) {
        New-Item -ItemType Directory $backup -Force | Out-Null
        Log "Initializing git repo in $gitDir (work tree: $watch)"
        & git @G init -b $branch | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    }
    # Lets you use git normally from backup\<alias> (git -C backup\<alias> log, etc.)
    Invoke-Git config core.worktree $watch | Out-Null
    # Saves and mods are already compressed (zip): without recompression the first commit is much faster
    Invoke-Git config core.compression 0 | Out-Null
    Invoke-Git config core.looseCompression 0 | Out-Null
    Update-Exclude
    if (-not (& git @G config user.name))  { Invoke-Git config user.name  'FilesBackup' | Out-Null }
    if (-not (& git @G config user.email)) { Invoke-Git config user.email 'filesbackup@localhost' | Out-Null }

    $current = (& git @G symbolic-ref --short HEAD 2>$null)
    if ($current -ne $branch) { Invoke-Git checkout -B $branch | Out-Null }

    $hasOrigin = (& git @G remote) -contains 'origin'
    if ($remote) {
        if ($hasOrigin) { Invoke-Git remote set-url origin $remote | Out-Null }
        else { Invoke-Git remote add origin $remote | Out-Null }
        Log "Remote configured: $remote"
    } else {
        if ($hasOrigin) { Invoke-Git remote remove origin | Out-Null }
        Log 'No remote: local-only backup'
    }
}

# Commit message summary: no quotes (they break argument passing on Windows) and no octal escapes
function Get-Summary { ((& git @G -c core.quotepath=false diff --cached --name-status) -join '; ').Replace('"', '') }

function Get-Rel($full) { $full.Substring($watch.Length).TrimStart('\').Replace('\', '/') }
function ConvertTo-WinPath($rel) { $rel.Replace('/', '\') }

function Get-BigFiles {
    $limit = $maxFileMB * 1MB
    $res = @{}
    foreach ($wp in $watchPaths) {
        Get-ChildItem -LiteralPath $wp -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt $limit } | ForEach-Object { $res[$_.FullName] = $_ }
    }
    $res.Values | Sort-Object FullName
}

$partRegex = '\.part\d{3}$'
$stateFile = Join-Path $backup 'bigfiles.json'
function Get-State {
    $h = @{}
    if (Test-Path $stateFile) {
        $o = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o) { $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    }
    $h
}
function Save-State($h) { ($h | ConvertTo-Json) | Set-Content $stateFile -Encoding UTF8 }

function Get-IndexFiles { (& git @G ls-files -z) -split "`0" | Where-Object { $_ } }

# base -> list of parts (.partNNN) in the index
function Get-TrackedParts {
    $h = @{}
    foreach ($p in (Get-IndexFiles | Where-Object { $_ -match $partRegex })) {
        $base = $p -replace $partRegex, ''
        if (-not $h.ContainsKey($base)) { $h[$base] = New-Object System.Collections.Generic.List[string] }
        $h[$base].Add($p)
    }
    $h
}

function Invoke-GitBatch($gitArgs, $paths) {
    for ($i = 0; $i -lt $paths.Count; $i += 50) {
        $batch = $paths[$i..([math]::Min($i + 49, $paths.Count - 1))]
        $out = & git @G @gitArgs -- @batch 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed: $out" }
    }
}

# Files that used to be stored whole and now exceed the limit: they become parts
function Remove-TrackedBig($bigRels) {
    if (-not $bigRels) { return }
    $idx = @{}; Get-IndexFiles | ForEach-Object { $idx[$_] = $true }
    $tr = @($bigRels | Where-Object { $idx.ContainsKey($_) })
    if ($tr) { Invoke-GitBatch @('update-index', '--force-remove') $tr }
}

# Removes from the index the parts whose original file no longer exists (or is no longer big)
function Remove-StaleParts($bigRels) {
    $tracked = Get-TrackedParts
    $state = Get-State; $stateChanged = $false
    foreach ($base in @($tracked.Keys)) {
        $baseExists = Test-Path -LiteralPath (Join-Path $watch (ConvertTo-WinPath $base))
        $partsOnDisk = Test-Path -LiteralPath (Join-Path $watch (ConvertTo-WinPath $tracked[$base][0]))
        $stale = ($baseExists -and ($bigRels -notcontains $base)) -or (-not $baseExists -and -not $partsOnDisk)
        if ($stale) {
            Invoke-GitBatch @('update-index', '--force-remove') $tracked[$base].ToArray()
            if ($state.ContainsKey($base)) { $state.Remove($base); $stateChanged = $true }
            Log "Parts removed from the backup (file no longer exists or is no longer big): $base" 'info'
        }
    }
    if ($stateChanged) { Save-State $state }
}

# Parts are not in the watched folder: skip-worktree stops "add -A" from seeing them as deleted
function Set-PartsSkipWorktree {
    $parts = @(Get-IndexFiles | Where-Object { $_ -match $partRegex -or $_ -like '.filesbackup/*' })
    if ($parts) { Invoke-GitBatch @('update-index', '--skip-worktree') $parts }
}
# README.md + config.json inside the repo (.filesbackup/) so a restore needs only the remote URL (Restore-Backup.ps1).
# They do not exist in the watched folder: they are prepared in backup\<alias>\.meta and indexed with another work tree.
# remoteUrl is NOT included (it may contain credentials).
function Update-Manifest {
    $d = Join-Path $backup '.meta\.filesbackup'
    New-Item -ItemType Directory $d -Force | Out-Null
    $entry = [ordered]@{
        alias = $Alias; root = $watch; watchPaths = @($watchPaths); branch = $branch
        programPath = $programPath; programArgs = $programArgs
        maxFileSizeMB = $maxFileMB; splitLargeFiles = $splitLarge
    }
    $enc = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $d 'config.json'), ($entry | ConvertTo-Json), $enc)
    $readme = @"
# Backup of '$Alias'

Repository generated by FilesWatcher (Watch-Backup.ps1). Do not edit by hand.

## Program configuration

| Field | Value |
|---|---|
| alias | $Alias |
| root folder (work tree) | $watch |
| watched paths | $($watchPaths -join '; ') |
| branch | $branch |
| programPath | $programPath |
| programArgs | $programArgs |
| maxFileSizeMB / splitLargeFiles | $maxFileMB / $splitLarge |

The same information in machine-readable form is in ``config.json`` (next to this file).

## Restore

Run ``Launch.cmd`` and choose *Restore*, or ``Restore-Backup.ps1 -Remote <remote-url>``. It creates the entry in
config.json, the repo in backup\<alias>, restores the folders under the root folder and joins the big files (.partNNN).
With ``-Root <folder>`` it restores to another path (another machine/user).
"@
    [IO.File]::WriteAllText((Join-Path $d 'README.md'), $readme, $enc)

    $paths = @('.filesbackup/README.md', '.filesbackup/config.json')
    $idx = @(Get-IndexFiles | Where-Object { $_ -like '.filesbackup/*' })
    if ($idx) { Invoke-GitBatch @('update-index', '--no-skip-worktree') $idx }
    $o = & git "--git-dir=$gitDir" "--work-tree=$(Join-Path $backup '.meta')" add -f -- @paths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git add manifest failed: $o" }
    Set-PartsSkipWorktree
}

function Get-PendingSigs {
    $h = @{}
    Get-ChildItem $backup -Directory -Filter 'parts_*' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $mf = Join-Path $_.FullName '_meta.json'
        if (Test-Path $mf) { (Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    }
    $h
}

# Snapshot-copies new/modified big files to parts_<timestamp>\ so they can be split afterwards
function New-PartsSnapshot($bigs) {
    if (-not $bigs) { return }
    $state = Get-State; $pending = Get-PendingSigs; $tracked = Get-TrackedParts
    $dir = $null; $meta = [ordered]@{}
    foreach ($f in $bigs) {
        $rel = Get-Rel $f.FullName
        $sig = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        if ($state[$rel] -eq $sig -and $tracked.ContainsKey($rel)) { continue }
        if ($pending[$rel] -eq $sig) { continue }
        if (-not $dir) { $dir = Join-Path $backup ('parts_{0:yyyyMMdd_HHmmss_fff}' -f (Get-Date)); New-Item -ItemType Directory $dir | Out-Null }
        $dest = Join-Path $dir (ConvertTo-WinPath $rel)
        New-Item -ItemType Directory (Split-Path $dest) -Force | Out-Null
        try {
            Log "Copying $rel ($([math]::Round($f.Length / 1MB, 1)) MB) to split..."
            $in = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $out = [IO.File]::Create($dest); try { $in.CopyTo($out, 4MB) } finally { $out.Dispose() } } finally { $in.Dispose() }
            $f.Refresh()
            if ("$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" -ne $sig) { throw 'the file changed during the copy (will retry)' }
            $meta[$rel] = $sig
            Log "Copy ready to split: $rel ($([math]::Round($f.Length / 1MB, 1)) MB) -> $(Split-Path $dir -Leaf)"
        } catch {
            Log "Could not copy $($f.FullName): $_" 'error'
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
    }
    if ($dir) {
        if ($meta.Count) { [IO.File]::WriteAllText((Join-Path $dir '_meta.json'), ($meta | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }
        else { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Split-File($src, $chunk) {
    $in = [IO.File]::OpenRead($src); $buf = New-Object byte[] (4MB); $i = 0
    try {
        while ($in.Position -lt $in.Length) {
            $i++
            $out = [IO.File]::Create(('{0}.part{1:D3}' -f $src, $i))
            try {
                $left = $chunk
                while ($left -gt 0) {
                    $r = $in.Read($buf, 0, [int][math]::Min($buf.Length, $left))
                    if ($r -le 0) { break }
                    $out.Write($buf, 0, $r); $left -= $r
                }
            } finally { $out.Dispose() }
        }
    } finally { $in.Dispose() }
}

# Processes the parts_* folders in chronological order (FIFO): split, commit, delete the folder. Returns $true if it committed
function Invoke-PartsQueue {
    $did = $false
    $dirs = @(Get-ChildItem $backup -Directory -Filter 'parts_*' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($d in $dirs) {
        $mf = Join-Path $d.FullName '_meta.json'
        if (-not (Test-Path $mf)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force; continue }
        try {
            $meta = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
            $tracked = Get-TrackedParts
            $newParts = New-Object System.Collections.Generic.List[string]
            foreach ($rel in ($meta.PSObject.Properties.Name)) {
                $src = Join-Path $d.FullName (ConvertTo-WinPath $rel)
                if (Test-Path -LiteralPath $src) {
                    Get-ChildItem -LiteralPath (Split-Path $src) -File -Filter ((Split-Path $src -Leaf) + '.part*') | Remove-Item -Force
                    Log "Splitting $rel ($([math]::Round((Get-Item -LiteralPath $src).Length / 1MB, 1)) MB) into $maxFileMB MB parts..."
                    Split-File $src $chunkBytes
                    Log "Split done: $rel"
                    Remove-Item -LiteralPath $src -Force
                }
                if ($tracked.ContainsKey($rel)) { Invoke-GitBatch @('update-index', '--force-remove') $tracked[$rel].ToArray() }
                $found = Get-ChildItem -LiteralPath (Split-Path $src) -File -Filter ((Split-Path $src -Leaf) + '.part*') | Where-Object { $_.Name -match $partRegex } | Sort-Object Name
                if (-not $found) { throw "No parts found for $rel in $($d.Name)" }
                foreach ($p in $found) { $newParts.Add((($p.FullName.Substring($d.FullName.Length).TrimStart('\')).Replace('\', '/'))) }
            }
            $PG = @("--git-dir=$gitDir", "--work-tree=$($d.FullName)")
            for ($i = 0; $i -lt $newParts.Count; $i += 50) {
                $batch = $newParts[$i..([math]::Min($i + 49, $newParts.Count - 1))]
                $o = & git @PG add -f -- @batch 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git add parts failed: $o" }
            }
            Set-PartsSkipWorktree
            & git @G diff --cached --quiet
            if ($LASTEXITCODE -ne 0) {
                $summary = Get-Summary
                Invoke-Git commit -m "Backup $($d.Name.Substring(6)) (large files split)" -m $summary | Out-Null
                Log "Parts commit created: $summary"
                $did = $true
            }
            $state = Get-State
            foreach ($p in $meta.PSObject.Properties) { $state[$p.Name] = $p.Value }
            Save-State $state
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
        } catch {
            Log "Failed processing $($d.Name): $_" 'error'
            break
        }
    }
    $did
}

$script:warnedBig = @{}
# No-split mode: unstages already-versioned files that have grown past the limit
function Remove-BigFiles {
    $limit = $maxFileMB * 1MB
    $names = (& git @G diff --cached --name-only --diff-filter=AM -z) -split "`0" | Where-Object { $_ }
    foreach ($rel in $names) {
        $full = Join-Path $watch $rel
        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt $limit) {
            & git @G reset -q -- $rel 2>&1 | Out-Null
            $key = "$full|$($item.Length)"
            if (-not $script:warnedBig[$key]) {
                $script:warnedBig[$key] = $true
                Log "File skipped from the backup for exceeding $maxFileMB MB ($([math]::Round($item.Length / 1MB, 1)) MB): $full" 'error'
            }
        }
    }
}

function Invoke-Backup {
    Log 'Scanning for big files...'
    $bigs = @()
    if ($maxFileMB -gt 0) { $bigs = @(Get-BigFiles) }
    $bigRels = @($bigs | ForEach-Object { Get-Rel $_.FullName })
    Update-Exclude $bigRels -Quiet
    Update-Manifest
    Set-PartsSkipWorktree
    foreach ($f in $bigs) {
        $key = "$($f.FullName)|$($f.Length)"
        if (-not $splitLarge -and -not $script:warnedBig[$key]) {
            $script:warnedBig[$key] = $true
            Log "File skipped from the backup for exceeding $maxFileMB MB ($([math]::Round($f.Length / 1MB, 1)) MB): $($f.FullName)" 'error'
        }
    }
    Log 'Adding files to the repo (git add; the first run can take several minutes)...'
    Invoke-Git add -A | Out-Null
    if ($maxFileMB -gt 0) {
        if ($splitLarge) {
            Remove-TrackedBig $bigRels
            Remove-StaleParts $bigRels
            Set-PartsSkipWorktree
            New-PartsSnapshot $bigs
        } else { Remove-BigFiles }
    }

    $committed = $false
    & git @G diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $summary = Get-Summary
        Invoke-Git commit -m "Backup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -m $summary | Out-Null
        Log "Commit created: $summary"
        $committed = $true
    }
    if ($splitLarge -and (Invoke-PartsQueue)) { $committed = $true }

    if ($committed -or $script:pendingPush) { Push-Remote } else { Log 'No changes' }
}

try { Initialize-Repo } catch { [void](Show-ErrorChoice 'Initialization error' "$_"); exit 1 }
if ($remote) { if (Confirm-Remote) { $script:pendingPush = $true } }
if ($Once) { Invoke-Backup; return }

$watchers = @(); $ids = @()
$n = 0
foreach ($wp in $watchPaths) {
    $fsw = New-Object System.IO.FileSystemWatcher $wp
    $fsw.IncludeSubdirectories = $true
    $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size, CreationTime'
    $fsw.EnableRaisingEvents = $true
    foreach ($ev in 'Changed', 'Created', 'Deleted', 'Renamed') {
        $id = "fw.$n.$ev"
        Register-ObjectEvent $fsw $ev -SourceIdentifier $id | Out-Null
        $ids += $id
    }
    $watchers += $fsw
    $n++
}

$proc = $null
if ($programPath) {
    if (-not (Test-Path $programPath)) { throw "programPath does not exist: $programPath" }
    $startArgs = @{ FilePath = $programPath; PassThru = $true; WorkingDirectory = (Split-Path $programPath) }
    if ($programArgs) { $startArgs.ArgumentList = $programArgs }
    $proc = Start-Process @startArgs
    Log "Program launched: $programPath (PID $($proc.Id))"
}
# The initial backup (slow with many files) runs after launching the program so it does not delay it
try { Invoke-Backup } catch { Log "Initial backup failed: $_" 'error' }

Log "Watching $($watchPaths -join ', ') (alias: $Alias, repo work tree: $watch, quiet period: ${debounce}s)"
try {
    while (-not ($proc -and $proc.HasExited)) {
        $first = Wait-Event -Timeout 1
        if (-not $first) { continue }

        # Quiet period: every new event restarts the count; the backup runs only after $debounce s without changes
        $lastEvent = Get-Date
        $count = 0
        while (((Get-Date) - $lastEvent).TotalSeconds -lt $debounce) {
            foreach ($e in @(Get-Event)) {
                $a = $e.SourceEventArgs
                $detail = if ($a.ChangeType -eq 'Renamed') { "$($a.OldFullPath) -> $($a.FullPath)" } else { $a.FullPath }
                Log "Change detected: $($a.ChangeType) $detail"
                Remove-Event -EventIdentifier $e.EventIdentifier
                $count++
                $lastEvent = Get-Date
            }
            Start-Sleep -Milliseconds 200
        }
        Log "$count events grouped; $debounce s without changes, starting commit"
        try { Invoke-Backup } catch { Log "Backup failed: $_" 'error' }
    }
    Log 'The program has exited: final backup'
    Start-Sleep -Seconds $debounce
    try { Invoke-Backup } catch { Log "Backup failed: $_" 'error' }
} finally {
    $ids | ForEach-Object { Unregister-Event $_ -ErrorAction SilentlyContinue }
    $watchers | ForEach-Object { $_.Dispose() }
}