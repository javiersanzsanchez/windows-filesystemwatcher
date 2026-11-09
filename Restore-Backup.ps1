<#
.SYNOPSIS
  Restores or syncs a backup from a git remote. Reads .filesbackup\config.json from the repo, creates/updates the
  config.json entry and the repo in backup\<alias>, restores the watched folders and joins the split big files.
  - New alias (from a remote URL): creates everything locally.
  - Existing alias: the REMOTE OVERWRITES the local state (folders, repo and config entry).
  Without parameters it opens a form to choose.
.EXAMPLE
  .\Restore-Backup.ps1                                           # form
  .\Restore-Backup.ps1 -Remote https://github.com/user/factorio-backup.git
  .\Restore-Backup.ps1 -Remote <url> -Root D:\Games\Factorio     # restore to another path
  .\Restore-Backup.ps1 -Remote <url> -Alias factorio2            # use another alias
#>
param(
    [string]$Remote,
    [string]$Root,
    [string]$Alias,
    [string]$Branch,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
try { $utf8 = New-Object Text.UTF8Encoding $false; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8 } catch {}
$env:GIT_TERMINAL_PROMPT = '1'

function Fail($m) { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
function Step($m) { Write-Host "==> $m" }

# Form: pick an existing alias or add a new one from a git remote URL
function Show-RestoreForm($programs) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Restore backup'; $f.StartPosition = 'CenterScreen'; $f.ClientSize = New-Object Drawing.Size(520, 330)
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true

    $rbExisting = New-Object Windows.Forms.RadioButton -Property @{ Text = 'Existing alias (config.json)'; Location = '12,12'; Size = '480,22'; Checked = $true }
    $list = New-Object Windows.Forms.ListBox -Property @{ Location = '30,38'; Size = '470,90' }
    foreach ($p in $programs) { [void]$list.Items.Add("$($p.alias)") }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $hint = New-Object Windows.Forms.Label -Property @{ Location = '30,130'; Size = '470,32'; ForeColor = 'DimGray'
        Text = 'Syncs from its remoteUrl: the remote OVERWRITES the local state (watched folders, repo in backup\<alias> and its config.json entry). Asks for confirmation.' }

    $rbNew = New-Object Windows.Forms.RadioButton -Property @{ Text = 'New, from a git remote URL'; Location = '12,170'; Size = '480,22' }
    $lblUrl = New-Object Windows.Forms.Label -Property @{ Text = 'Remote URL:'; Location = '30,198'; Size = '110,20' }
    $tbUrl = New-Object Windows.Forms.TextBox -Property @{ Location = '145,195'; Size = '355,22'; Enabled = $false }
    $lblRoot = New-Object Windows.Forms.Label -Property @{ Text = 'Folder (optional):'; Location = '30,228'; Size = '110,20' }
    $tbRoot = New-Object Windows.Forms.TextBox -Property @{ Location = '145,225'; Size = '285,22'; Enabled = $false }
    $btnBrowse = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = '435,224'; Size = '65,24'; Enabled = $false }
    $lblAlias = New-Object Windows.Forms.Label -Property @{ Text = 'Alias (optional):'; Location = '30,258'; Size = '110,20' }
    $tbAlias = New-Object Windows.Forms.TextBox -Property @{ Location = '145,255'; Size = '355,22'; Enabled = $false }

    $ok = New-Object Windows.Forms.Button -Property @{ Text = 'Restore'; Location = '330,295'; Size = '85,28'; DialogResult = 'OK' }
    $cancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = '420,295'; Size = '80,28'; DialogResult = 'Cancel' }
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $toggle = {
        $e = $rbNew.Checked
        $list.Enabled = -not $e
        $tbUrl.Enabled = $e; $tbRoot.Enabled = $e; $btnBrowse.Enabled = $e; $tbAlias.Enabled = $e
    }
    $rbExisting.Add_CheckedChanged($toggle); $rbNew.Add_CheckedChanged($toggle)
    $btnBrowse.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') { $tbRoot.Text = $d.SelectedPath }
    })
    $f.Add_FormClosing({
        param($s, $e)
        if ($f.DialogResult -ne 'OK') { return }
        if ($rbNew.Checked -and -not $tbUrl.Text.Trim()) { [void][Windows.Forms.MessageBox]::Show('Enter the remote URL.'); $e.Cancel = $true }
        if ($rbExisting.Checked -and $list.SelectedIndex -lt 0) { [void][Windows.Forms.MessageBox]::Show('Select an alias.'); $e.Cancel = $true }
    })
    $f.Controls.AddRange(@($rbExisting, $list, $hint, $rbNew, $lblUrl, $tbUrl, $lblRoot, $tbRoot, $btnBrowse, $lblAlias, $tbAlias, $ok, $cancel))
    if ($f.ShowDialog() -ne 'OK') { return $null }
    if ($rbExisting.Checked) { return @{ Mode = 'existing'; Alias = "$($list.SelectedItem)" } }
    @{ Mode = 'new'; Remote = $tbUrl.Text.Trim(); Root = $tbRoot.Text.Trim(); Alias = $tbAlias.Text.Trim() }
}

function Get-CommonRoot($paths) {
    $split = @($paths | ForEach-Object { , ($_.TrimEnd('\') -split '\\') })
    $common = $split[0]
    foreach ($s in $split) {
        $n = 0
        while ($n -lt $common.Count -and $n -lt $s.Count -and $common[$n] -ieq $s[$n]) { $n++ }
        if ($n -eq 0) { return '' }
        $common = $common[0..($n - 1)]
    }
    $common -join '\'
}

# Joins every complete group of name.ext.partNNN found in the watched paths of the alias, then deletes the parts
function Join-Parts($Alias) {
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = @($cfg.programs) | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
    foreach ($wp in @($p.watchPaths)) {
        if (-not (Test-Path -LiteralPath $wp)) { Write-Host "[warning] Path of '$Alias' does not exist: $wp"; continue }
        $groups = Get-ChildItem -LiteralPath $wp -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.part\d{3}$' } |
            Group-Object { $_.FullName -replace '\.part\d{3}$', '' }
        foreach ($g in $groups) {
            $parts = @($g.Group | Sort-Object Name)
            $nums = @($parts | ForEach-Object { [int]($_.Name -replace '^.*\.part', '') })
            if (-not (($nums[0] -eq 1) -and (($nums[-1] - $nums[0] + 1) -eq $nums.Count))) {
                Write-Host "[warning] Missing parts, cannot join: $($g.Name)"; continue
            }
            $tmpFile = "$($g.Name).joining"
            try {
                $out = [IO.File]::Create($tmpFile)
                try {
                    foreach ($part in $parts) {
                        $in = [IO.File]::OpenRead($part.FullName)
                        try { $in.CopyTo($out, 4MB) } finally { $in.Dispose() }
                    }
                } finally { $out.Dispose() }
                Move-Item -LiteralPath $tmpFile -Destination $g.Name -Force
                $parts | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
                Write-Host "Joined: $($g.Name)"
            } catch {
                Write-Host "[error] $($g.Name): $_"
                Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-Restore($Remote, $Root, $Alias, $Branch, $Existing) {
$tmp = Join-Path $PSScriptRoot 'backup\_restore_tmp'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
# Existing alias with a repo: sync inside its own repo; otherwise download into a temporary repo
$existingRepo = $Existing -and (Test-Path (Join-Path $PSScriptRoot "backup\$Alias\.git"))
if ($existingRepo) { $tg = "--git-dir=$(Join-Path $PSScriptRoot "backup\$Alias\.git")" }
else {
    New-Item -ItemType Directory $tmp -Force | Out-Null
    $tg = "--git-dir=$tmp\.git"
}

try {
    Step "Downloading $Remote"
    if ($existingRepo) {
        if ((& git $tg remote) -contains 'origin') { & git $tg remote set-url origin $Remote } else { & git $tg remote add origin $Remote }
    } else {
        & git init -q $tmp 2>&1 | Out-Null
        & git $tg remote add origin $Remote
    }
    & git $tg fetch -q origin 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Fail 'Could not download the remote (wrong URL or credentials).' }

    if (-not $Branch) {
        $sym = (& git $tg ls-remote --symref origin HEAD 2>$null) | Where-Object { $_ -match '^ref: refs/heads/' } | Select-Object -First 1
        $Branch = if ($sym) { ($sym -replace '^ref: refs/heads/', '') -replace '\s+HEAD$', '' } else { 'main' }
    }
    Step "Branch: $Branch"

    $json = & git $tg show "origin/${Branch}:.filesbackup/config.json" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { Fail "The remote has no .filesbackup/config.json on branch '$Branch' (it was not created by Watch-Backup.ps1, or comes from an older version)." }
    $m = ($json -join "`n") | ConvertFrom-Json

    if (-not $Alias) { $Alias = "$($m.alias)" }
    if ($Alias -notmatch '^[\w.-]+$') { Fail "Invalid alias: '$Alias'" }
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Existing -and (@($cfg.programs) | Where-Object { $_.alias -eq $Alias })) { Fail "The alias '$Alias' already exists in $ConfigPath. Use -Alias <other>." }
    $backup = Join-Path $PSScriptRoot "backup\$Alias"
    if (-not $existingRepo -and (Test-Path $backup)) { Fail "$backup already exists. Use -Alias <other> or delete it." }

    $origRoot = "$($m.root)".TrimEnd('\')
    $mapPaths = { param($root) @($m.watchPaths | ForEach-Object {
        $p = "$_"
        if ($p.StartsWith($origRoot, [StringComparison]::OrdinalIgnoreCase)) { $root + $p.Substring($origRoot.Length) }
        else { Fail "The path '$p' is not under the root '$origRoot'." }
    }) }
    if ($Existing -and @($Existing.watchPaths).Count) {
        # Alias already defined in config.json: the root is this machine's; remote paths are aligned to it
        $newRoot = Get-CommonRoot @($Existing.watchPaths | ForEach-Object { "$_" })
        if (-not $newRoot) { Fail "The paths of '$Alias' do not share a common directory." }
        $paths = & $mapPaths $newRoot
    } else {
        $newRoot = if ($Root) { $Root.TrimEnd('\') } else { $origRoot }
        $paths = & $mapPaths $newRoot
    }
    $drive = Split-Path $newRoot -Qualifier -ErrorAction SilentlyContinue
    if ($drive -and -not (Test-Path "$drive\")) { Fail "Drive $drive does not exist on this machine. Use -Root <folder> to restore to another path." }

    Step "Alias '$Alias', root folder: $newRoot"
    New-Item -ItemType Directory $newRoot -Force | Out-Null
    if (-not $existingRepo) { Move-Item $tmp $backup }
    $gitDir = Join-Path $backup '.git'
    $G = @("--git-dir=$gitDir", "--work-tree=$newRoot")
    & git @G config core.worktree $newRoot
    & git @G config user.name 'FilesBackup'
    & git @G config user.email 'filesbackup@localhost'

    if ($existingRepo) {
        # Clear skip-worktree so the checkout also rewrites the parts and the manifest
        $old = @((& git @G ls-files -z) -split "`0" | Where-Object { $_ -match '\.part\d{3}$' -or $_ -like '.filesbackup/*' })
        for ($i = 0; $i -lt $old.Count; $i += 50) {
            $batch = $old[$i..([math]::Min($i + 49, $old.Count - 1))]
            & git @G update-index --no-skip-worktree -- @batch
        }
    }

    Step 'Restoring files'
    $out = & git @G checkout -q -f -B $Branch "origin/$Branch" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "checkout failed (existing files in $newRoot may be in the way):`n$out" }
    & git @G branch -q --set-upstream-to="origin/$Branch" 2>&1 | Out-Null

    # The manifest and parts must not count as files of the folder: skip-worktree and removed from disk
    $files = (& git @G ls-files -z) -split "`0" | Where-Object { $_ }
    $managed = @($files | Where-Object { $_ -match '\.part\d{3}$' -or $_ -like '.filesbackup/*' })
    for ($i = 0; $i -lt $managed.Count; $i += 50) {
        $batch = $managed[$i..([math]::Min($i + 49, $managed.Count - 1))]
        & git @G update-index --skip-worktree -- @batch
    }
    Remove-Item (Join-Path $newRoot '.filesbackup') -Recurse -Force -ErrorAction SilentlyContinue

    Step "$(if ($Existing) { 'Updating' } else { 'Adding' }) '$Alias' in $ConfigPath"
    Copy-Item $ConfigPath "$ConfigPath.bak" -Force
    if ($Existing) {
        $e = @($cfg.programs) | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
        $e | Add-Member -NotePropertyName watchPaths -NotePropertyValue $paths -Force
        $e | Add-Member -NotePropertyName branch -NotePropertyValue $Branch -Force
        $e | Add-Member -NotePropertyName maxFileSizeMB -NotePropertyValue $m.maxFileSizeMB -Force
        $e | Add-Member -NotePropertyName splitLargeFiles -NotePropertyValue $m.splitLargeFiles -Force
        # programPath/programArgs depend on the machine: taken from the remote only when empty here
        if (-not "$($e.programPath)".Trim()) { $e | Add-Member -NotePropertyName programPath -NotePropertyValue "$($m.programPath)" -Force }
        if (-not "$($e.programArgs)".Trim()) { $e | Add-Member -NotePropertyName programArgs -NotePropertyValue "$($m.programArgs)" -Force }
    } else {
        $entry = [pscustomobject][ordered]@{
            alias = $Alias; watchPaths = $paths; remoteUrl = $Remote; branch = $Branch
            programPath = "$($m.programPath)"; programArgs = "$($m.programArgs)"
            maxFileSizeMB = $m.maxFileSizeMB; splitLargeFiles = $m.splitLargeFiles
        }
        $cfg.programs = @(@($cfg.programs) + $entry)
    }
    [IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))

    $partFiles = @($managed | Where-Object { $_ -match '\.part\d{3}$' })
    if ($partFiles) {
        Step 'Joining big files'
        $bases = @($partFiles | ForEach-Object { $_ -replace '\.part\d{3}$', '' } | Sort-Object -Unique)
        # When syncing, the local version of the big file is overwritten too
        if ($Existing) { foreach ($b in $bases) { Remove-Item -LiteralPath (Join-Path $newRoot ($b.Replace('/', '\'))) -Force -ErrorAction SilentlyContinue } }
        Join-Parts $Alias

        # Initial state so Watch-Backup.ps1 does not split again what is already stored
        $state = @{}
        foreach ($base in $bases) {
            $f = Get-Item -LiteralPath (Join-Path $newRoot ($base.Replace('/', '\'))) -ErrorAction SilentlyContinue
            if ($f) { $state[$base] = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" }
        }
        Set-Content (Join-Path $backup 'bigfiles.json') ($state | ConvertTo-Json) -Encoding UTF8
    }

    if ($m.programPath -and -not (Test-Path "$($m.programPath)")) {
        Write-Host "[warning] programPath does not exist on this machine: $($m.programPath). Edit it in $ConfigPath." -ForegroundColor Yellow
    }
    Step "Done. Restored to $newRoot. Run it with: Launch.cmd (Run a program) or Launch.cmd $Alias"
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
}
if ($Remote) { Invoke-Restore $Remote $Root $Alias $Branch $null; return }

$cfg0 = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$programs0 = @($cfg0.programs)
$r = Show-RestoreForm $programs0
if (-not $r) { Write-Host 'Cancelled.'; return }

if ($r.Mode -eq 'new') {
    Invoke-Restore $r.Remote $r.Root $r.Alias $null $null
    return
}

# Existing alias: the remote OVERWRITES the local state (watched folders, backup\<alias> repo and config.json entry)
$prog = $programs0 | Where-Object { $_.alias -eq $r.Alias } | Select-Object -First 1
$url = "$($prog.remoteUrl)".Trim()
if (-not $url) { Fail "The alias '$($r.Alias)' has no remoteUrl in config.json: nothing to restore from." }
Add-Type -AssemblyName System.Windows.Forms
$msg = "This will OVERWRITE the local state of '$($r.Alias)' with the content of the remote:`n$url`n`n- Folders: $(@($prog.watchPaths) -join '; ')`n- Local changes that were not backed up will be lost.`n- Its config.json entry will be updated (local programPath/programArgs are kept).`n`nContinue?"
$ans = [Windows.Forms.MessageBox]::Show($msg, 'Sync from remote', 'YesNo', 'Warning', 'Button2')
if ($ans -ne 'Yes') { Write-Host 'Cancelled.'; return }
Invoke-Restore $url $null $r.Alias "$($prog.branch)" $prog