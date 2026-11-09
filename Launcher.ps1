<#
.SYNOPSIS
  FilesWatcher launcher menu: add a program to watch, run a known alias (or create a desktop shortcut for it),
  or restore/sync from a git remote.
  Started by Launch.cmd when no alias is given.
#>
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# Started hidden (-WindowStyle Hidden): the first window would inherit SW_HIDE, so every form forces itself visible
Add-Type -Namespace Native -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'

$watchScript = Join-Path $PSScriptRoot 'Watch-Backup.ps1'
$restoreScript = Join-Path $PSScriptRoot 'Restore-Backup.ps1'

function Show-Dialog($form) {
    $form.TopMost = $true
    $form.Add_Shown({ param($s, $e) [void][Native.Win]::ShowWindow($s.Handle, 5); $s.Activate() })
    $form.ShowDialog()
}

function Get-Config { Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }

function Save-Config($cfg) {
    if (Test-Path $ConfigPath) { Copy-Item $ConfigPath "$ConfigPath.bak" -Force }
    [IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
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

function Get-WatchArgs($alias) {
    "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`" -Alias `"$alias`" -ConfigPath `"$ConfigPath`""
}

function New-Button($text, $x, $y, $w, $h = 30) {
    New-Object Windows.Forms.Button -Property @{ Text = $text; Location = New-Object Drawing.Point($x, $y); Size = New-Object Drawing.Size($w, $h) }
}

# ---------- Add a program ----------
function Show-AddForm {
    $f = New-Object Windows.Forms.Form -Property @{ Text = 'Add a program to watch'; StartPosition = 'CenterScreen'
        ClientSize = New-Object Drawing.Size(560, 470); FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false }
    function Row($label, $y, $width = 340) {
        $l = New-Object Windows.Forms.Label -Property @{ Text = $label; Location = New-Object Drawing.Point(12, ($y + 3)); Size = New-Object Drawing.Size(150, 20) }
        $t = New-Object Windows.Forms.TextBox -Property @{ Location = New-Object Drawing.Point(165, $y); Size = New-Object Drawing.Size($width, 22) }
        $f.Controls.AddRange(@($l, $t)); $t
    }
    $tbAlias = Row 'Alias (e.g. factorio):' 12 383
    $tbRemote = Row 'Git remote URL (optional):' 42 383
    $tbBranch = Row 'Branch:' 72 383; $tbBranch.Text = 'main'
    $tbExe = Row 'Program .exe (optional):' 102
    $btnExe = New-Button 'Browse...' 510 100 40 26; $btnExe.Text = '...'
    $tbArgs = Row 'Program arguments:' 132 383

    $lblF = New-Object Windows.Forms.Label -Property @{ Text = 'Folders to watch:'; Location = New-Object Drawing.Point(12, 168); Size = New-Object Drawing.Size(300, 20) }
    $list = New-Object Windows.Forms.ListBox -Property @{ Location = New-Object Drawing.Point(12, 190); Size = New-Object Drawing.Size(496, 200); HorizontalScrollbar = $true }
    $btnAdd = New-Button '+' 514 190 36 30
    $btnDel = New-Button '-' 514 226 36 30
    $note = New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(12, 392); Size = New-Object Drawing.Size(540, 36); ForeColor = 'DarkRed'
    Text = 'Remote: create an EMPTY repo first and manage git credentials yourself (Git Credential Manager login, token/SSH key). If access fails, the watcher shows the git commands to run manually. Empty remote = local-only backup.' }
    $ok = New-Button 'Add' 380 430 80; $ok.DialogResult = 'OK'
    $cancel = New-Button 'Cancel' 470 430 80; $cancel.DialogResult = 'Cancel'
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $btnExe.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Programs (*.exe;*.lnk;*.bat;*.cmd)|*.exe;*.lnk;*.bat;*.cmd|All files (*.*)|*.*' }
        if ($d.ShowDialog() -eq 'OK') { $tbExe.Text = $d.FileName }
    }.GetNewClosure())
    $btnAdd.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Select a folder to watch' }
        if ($d.ShowDialog() -eq 'OK' -and $list.Items -notcontains $d.SelectedPath) { [void]$list.Items.Add($d.SelectedPath) }
    }.GetNewClosure())
    $btnDel.Add_Click({ if ($list.SelectedIndex -ge 0) { $list.Items.RemoveAt($list.SelectedIndex) } }.GetNewClosure())

    $f.Add_FormClosing({
        param($s, $e)
        if ($s.DialogResult -ne 'OK') { return }
        $alias = $tbAlias.Text.Trim()
        $err = $null
        if ($alias -notmatch '^[\w.-]+$') { $err = "The alias may only contain letters, digits, '.', '_' and '-'." }
        elseif (@((Get-Config).programs) | Where-Object { $_.alias -eq $alias }) { $err = "The alias '$alias' already exists." }
        elseif ($list.Items.Count -eq 0) { $err = 'Add at least one folder to watch (+ button).' }
        elseif ($tbExe.Text.Trim() -and -not (Test-Path -LiteralPath $tbExe.Text.Trim())) { $err = 'The program path does not exist.' }
        elseif (-not (Get-CommonRoot @($list.Items | ForEach-Object { "$_" }))) { $err = 'The folders must be on the same drive.' }
        if ($err) { [void][Windows.Forms.MessageBox]::Show($err, 'Add a program'); $e.Cancel = $true }
    }.GetNewClosure())

    $f.Controls.AddRange(@($btnExe, $lblF, $list, $btnAdd, $btnDel, $note, $ok, $cancel))
    if ((Show-Dialog $f) -ne 'OK') { return $null }
    [pscustomobject][ordered]@{
        alias = $tbAlias.Text.Trim(); watchPaths = @($list.Items | ForEach-Object { "$_" })
        remoteUrl = $tbRemote.Text.Trim(); branch = $(if ($tbBranch.Text.Trim()) { $tbBranch.Text.Trim() } else { 'main' })
        programPath = $tbExe.Text.Trim(); programArgs = $tbArgs.Text.Trim()
    }
}

function Invoke-AddProgram {
    $entry = Show-AddForm
    if (-not $entry) { return }
    $cfg = Get-Config
    if (-not $cfg.PSObject.Properties['programs']) { $cfg | Add-Member -NotePropertyName programs -NotePropertyValue @() }
    $cfg.programs = @(@($cfg.programs) + $entry)
    Save-Config $cfg
    $msg = "'$($entry.alias)' added to config.json.`nUse 'Run a program' to launch it or create a desktop shortcut."
    if ($entry.remoteUrl) {
        $bk = Join-Path $PSScriptRoot "backup\$($entry.alias)"
        $msg += "`n`nIMPORTANT: you are responsible for the remote and its credentials. The remote repo must exist and you must be logged in. If the first launch reports an access or push error, authenticate once manually in a console:`n  cd `"$bk`"`n  git --git-dir=.git add -A`n  git --git-dir=.git commit -m init`n  git --git-dir=.git push -u origin $($entry.branch)`nThen press Retry in the dialog."
    }
    [void][Windows.Forms.MessageBox]::Show($msg, 'Add a program')
}

# ---------- Run a known alias / desktop shortcut ----------
function New-DesktopShortcut($prog) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop "$($prog.alias).lnk"
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = (Get-Command powershell.exe).Source
    $s.Arguments = Get-WatchArgs $prog.alias
    $s.WorkingDirectory = $PSScriptRoot
    $s.WindowStyle = 7
    $s.Description = "Runs $($prog.alias) with FilesWatcher backup"
    $exe = "$($prog.programPath)".Trim()
    if ($exe -and (Test-Path -LiteralPath $exe)) { $s.IconLocation = "$exe,0" }
    $s.Save()
    $lnk
}

function Invoke-RunProgram {
    $programs = @((Get-Config).programs)
    if (-not $programs) { [void][Windows.Forms.MessageBox]::Show('No programs configured yet. Use "Add a program to watch" first.', 'Run a program'); return }
    $f = New-Object Windows.Forms.Form -Property @{ Text = 'Run a program'; StartPosition = 'CenterScreen'
        ClientSize = New-Object Drawing.Size(420, 290); FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false }
    $lbl = New-Object Windows.Forms.Label -Property @{ Text = 'Select an alias:'; Location = New-Object Drawing.Point(12, 12); Size = New-Object Drawing.Size(390, 20) }
    $list = New-Object Windows.Forms.ListBox -Property @{ Location = New-Object Drawing.Point(12, 36); Size = New-Object Drawing.Size(396, 170) }
    foreach ($p in $programs) { [void]$list.Items.Add("$($p.alias)") }
    $list.SelectedIndex = 0
    $now = New-Button 'Launch now' 12 220 120 32
    $shortcut = New-Button 'Create desktop shortcut' 140 220 160 32
    $cancel = New-Button 'Cancel' 308 220 100 32; $cancel.DialogResult = 'Cancel'
    $hint = New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(12, 258); Size = New-Object Drawing.Size(396, 26); ForeColor = 'DimGray'
        Text = 'The shortcut starts the watcher and the real program together; use it instead of the original one.' }
    foreach ($b in @($now, $shortcut)) { $b.Add_Click({ param($s, $e) if ($list.SelectedIndex -ge 0) { $s.FindForm().Tag = $s.Text; $s.FindForm().Close() } }.GetNewClosure()) }
    $f.CancelButton = $cancel
    $f.Controls.AddRange(@($lbl, $list, $now, $shortcut, $cancel, $hint))
    [void](Show-Dialog $f)
    if (-not $f.Tag) { return }
    $prog = $programs | Where-Object { $_.alias -eq "$($list.SelectedItem)" } | Select-Object -First 1
    if ($f.Tag -eq 'Launch now') {
        Start-Process powershell.exe -ArgumentList (Get-WatchArgs $prog.alias) -WindowStyle Hidden
    } else {
        $lnk = New-DesktopShortcut $prog
        [void][Windows.Forms.MessageBox]::Show("Shortcut created:`n$lnk", 'Run a program')
    }
}

# ---------- Restore ----------
function Invoke-Restore {
    $cmd = "& '$restoreScript' -ConfigPath '$ConfigPath'; Write-Host; Read-Host 'Press Enter to close'"
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`"$cmd`"")
}

# ---------- Main menu ----------
while ($true) {
    $f = New-Object Windows.Forms.Form -Property @{ Text = 'FilesWatcher'; StartPosition = 'CenterScreen'
        ClientSize = New-Object Drawing.Size(360, 230); FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false }
    $defs = @(@('Add a program to watch', 'add'), @('Run a program', 'run'), @('Restore / sync from a remote', 'restore'), @('Exit', 'exit'))
    $y = 16
    foreach ($d in $defs) {
        $b = New-Button $d[0] 30 $y 300 40; $b.Tag = $d[1]
        $b.Add_Click({ param($s, $e) $s.FindForm().Tag = $s.Tag; $s.FindForm().Close() })
        $f.Controls.Add($b); $y += 52
    }
    [void](Show-Dialog $f)
    try {
        switch ($f.Tag) {
            'add'     { Invoke-AddProgram }
            'run'     { Invoke-RunProgram }
            'restore' { Invoke-Restore }
            default   { return }
        }
    } catch {
        [void][Windows.Forms.MessageBox]::Show("$_", 'FilesWatcher - error')
    }
}