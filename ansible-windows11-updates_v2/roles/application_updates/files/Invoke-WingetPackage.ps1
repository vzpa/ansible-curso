# Ejecuta una evaluación/actualización de un único paquete WinGet por ID exacto.
# Compatible con Windows PowerShell 5.1 y ansible.windows.win_powershell.
# Nunca utiliza --all. Conserva evidencia por paquete en LogDirectory.
param(
  [Parameter(Mandatory)][string]$PackageId,
  [string]$Source = 'winget',
  [Parameter(Mandatory)][string]$Mode,
  [int]$TimeoutSeconds = 900,
  [string[]]$ProcessNames = @(),
  [string]$CloseProcesses = 'false',
  [string]$ForceClose = 'false',
  [int]$GraceSeconds = 20,
  [string]$LogDirectory = 'C:\Logs\ansible_updates\winget'
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$ProcessNames = @($ProcessNames | Where-Object { $_ -and "$($_)".Trim() })
$env:NO_COLOR = '1'
$env:WINGET_DISABLE_INTERACTIVITY = '1'

function ConvertTo-Flag {
  param([string]$Value)
  return ("$Value" -match '^(?i:true|1|yes)$')
}

function Find-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $roots = @(
    "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe",
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
  )
  foreach ($pattern in $roots) {
    $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

function Invoke-Winget {
  param([string]$Exe, [string[]]$WgArgs, [int]$Timeout)
  $outFile = [IO.Path]::GetTempFileName()
  $errFile = [IO.Path]::GetTempFileName()
  $process = $null
  try {
    $process = Start-Process -FilePath $Exe -ArgumentList $WgArgs -NoNewWindow -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $process.Handle
    $timedOut = -not $process.WaitForExit($Timeout * 1000)
    if ($timedOut) {
      try { $process.Kill() } catch { }
      try { $process.WaitForExit() } catch { }
    }
    return [pscustomobject]@{
      args = ($WgArgs -join ' ')
      rc = $(if ($timedOut) { $null } else { $process.ExitCode })
      timed_out = $timedOut
      stdout = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8)
      stderr = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8)
    }
  }
  finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# WinGet puede emitir una o varias separaciones entre columnas según la versión,
# el idioma y el ancho de consola. Se localiza el ID como token exacto y se
# reconstruye el nombre con todos los tokens anteriores; no se depende de los
# encabezados localizados ni de que las columnas estén alineadas con varios espacios.
function Find-PackageRow {
  param([string]$Output, [string]$ExactId)
  foreach ($line in ($Output -split "`r?`n")) {
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }
    $parts = @($trimmed -split '\s+' | Where-Object { $_ -ne '' })
    for ($i = 0; $i -lt $parts.Count; $i++) {
      if ($parts[$i].Trim() -ieq $ExactId) {
        return [pscustomobject]@{
          name = $(if ($i -gt 0) { $parts[0..($i - 1)] -join ' ' } else { '' })
          id = $parts[$i]
          installed_version = $(if ($i + 1 -lt $parts.Count) { $parts[$i + 1] } else { '' })
          available_version = $(if ($i + 2 -lt $parts.Count) { $parts[$i + 2] } else { '' })
          source = $(if ($i + 3 -lt $parts.Count) { $parts[$i + 3] } else { '' })
          raw_line = $trimmed
        }
      }
    }
  }
  return $null
}

function Stop-AppProcesses {
  param([string[]]$Names, [bool]$Force, [int]$Grace)
  $info = [ordered]@{ found = @(); closed_gracefully = @(); force_killed = @(); still_running = @() }
  $procs = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return $info }
  $info.found = @($procs | ForEach-Object { "$($_.ProcessName)#$($_.Id)" })
  foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch { } }
  $deadline = (Get-Date).AddSeconds($Grace)
  do {
    Start-Sleep -Seconds 1
    $alive = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  } while ($alive.Count -gt 0 -and (Get-Date) -lt $deadline)
  $aliveIds = @($alive | ForEach-Object { $_.Id })
  $info.closed_gracefully = @($procs | Where-Object { $aliveIds -notcontains $_.Id } |
    ForEach-Object { "$($_.ProcessName)#$($_.Id)" })
  if ($alive.Count -gt 0 -and $Force) {
    foreach ($p in $alive) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $info.force_killed += "$($p.ProcessName)#$($p.Id)" } catch { }
    }
    Start-Sleep -Seconds 2
    $alive = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  }
  $info.still_running = @($alive | ForEach-Object { "$($_.ProcessName)#$($_.Id)" })
  return $info
}

$safeId = ($PackageId -replace '[^A-Za-z0-9._+-]', '_')
$logFile = Join-Path $LogDirectory ($safeId + '.json')
$res = [ordered]@{
  id = $PackageId; source = $Source; mode = $Mode; winget_path = $null; winget_version = $null
  classification = 'script_error'; error = ''; before_version = ''; available_version = ''
  after_version = ''; log_file = $logFile
}

try {
  if ($Mode -notin @('check', 'upgrade')) { throw "Mode inválido: $Mode" }
  if ($PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { throw "PackageId inválido: $PackageId" }
  if ($Source -notin @('winget', 'msstore')) { throw "Source inválido: $Source" }
  foreach ($n in $ProcessNames) { if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._\-]*$') { throw "Nombre de proceso inválido: $n" } }

  $wg = Find-Winget
  $res.winget_path = $wg
  if (-not $wg) {
    $res.classification = 'winget_not_found'
  }
  else {
    $versionResult = Invoke-Winget $wg @('--version') $TimeoutSeconds
    $res.winget_version = "$($versionResult.stdout)".Trim()
    $common = @('--id', $PackageId, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    $res.before = Invoke-Winget $wg (@('list') + $common) $TimeoutSeconds
    $beforeRow = Find-PackageRow -Output $res.before.stdout -ExactId $PackageId
    if ($beforeRow) { $res.before_version = $beforeRow.installed_version }

    if ($res.before.timed_out) {
      $res.classification = 'timeout'
    }
    elseif ($res.before.rc -ne 0) {
      $res.classification = 'other_rc'
    }
    elseif (-not $beforeRow -and $res.before.stdout -match [regex]::Escape($PackageId)) {
      $res.classification = 'upgrade_unverified'
    }
    elseif (-not $beforeRow) {
      $res.classification = 'not_installed'
    }
    else {
      $res.check = Invoke-Winget $wg (@('list', '--upgrade-available') + $common) $TimeoutSeconds
      $updateRow = Find-PackageRow -Output $res.check.stdout -ExactId $PackageId
      if ($updateRow) {
        $res.available_version = $updateRow.available_version
        $res.classification = 'update_available'
      }
      elseif ($res.check.timed_out) {
        $res.classification = 'timeout'
      }
      elseif ($res.check.rc -eq 0 -and $res.check.stdout -match [regex]::Escape($PackageId)) {
        $res.classification = 'upgrade_unverified'
      }
      elseif ($res.check.rc -eq 0) {
        $res.classification = 'up_to_date'
      }
      else {
        $res.classification = 'other_rc'
      }

      if ($Mode -eq 'upgrade' -and $res.classification -eq 'update_available') {
        $blocked = $false
        if ((ConvertTo-Flag $CloseProcesses) -and $ProcessNames.Count -gt 0) {
          $res.processes = Stop-AppProcesses -Names $ProcessNames -Force (ConvertTo-Flag $ForceClose) -Grace $GraceSeconds
          if ($res.processes.still_running.Count -gt 0) { $blocked = $true; $res.classification = 'blocked_by_process' }
        }
        if (-not $blocked) {
          $res.upgrade = Invoke-Winget $wg (@('upgrade') + $common + @('--silent', '--accept-package-agreements')) $TimeoutSeconds
          if ($res.upgrade.timed_out) {
            $res.classification = 'timeout'
          }
          else {
            $res.after = Invoke-Winget $wg (@('list') + $common) $TimeoutSeconds
            $afterRow = Find-PackageRow -Output $res.after.stdout -ExactId $PackageId
            if ($afterRow) { $res.after_version = $afterRow.installed_version }
            $res.post_check = Invoke-Winget $wg (@('list', '--upgrade-available') + $common) $TimeoutSeconds
            $postRow = Find-PackageRow -Output $res.post_check.stdout -ExactId $PackageId
            if ($res.upgrade.rc -eq 0 -and $res.after.rc -eq 0 -and $afterRow -and
                $res.post_check.rc -eq 0 -and -not $postRow -and
                $res.before_version -ne $res.after_version) {
              $res.classification = 'updated'
              $Ansible.Changed = $true
            }
            elseif ($res.upgrade.rc -eq 0 -and $postRow) {
              $res.classification = 'still_outdated'
            }
            elseif ($res.upgrade.rc -eq 0) {
              $res.classification = 'upgrade_unverified'
            }
            else {
              $res.classification = 'other_rc'
            }
          }
        }
      }
    }
  }
}
catch {
  $res.classification = 'script_error'
  $res.error = $_.Exception.Message
}

# Evidencia persistente: un JSON independiente por ID, incluso si la evaluación falla.
try {
  if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
  }
  $res.generated_at = (Get-Date).ToString('o')
  $json = $res | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($logFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}
catch {
  $res.classification = 'log_write_failed'
  $res.log_error = $_.Exception.Message
}
$Ansible.Result = $res
