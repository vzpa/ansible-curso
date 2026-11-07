# Invoke-WingetPackage.ps1
#
# Evalúa (y opcionalmente actualiza) UN paquete de WinGet por ID EXACTO.
# Se ejecuta con ansible.windows.win_powershell (variable $Ansible disponible).
# Compatible con Windows PowerShell 5.1 (sin operadores ni cmdlets exclusivos de PS 7).
#
# Garantías:
#   - Nunca usa `--all`.
#   - No depende de texto localizado de WinGet: se guardan rc, stdout y stderr crudos.
#   - Solo cierra procesos si CloseProcesses=true Y hay ProcessNames Y hay una
#     actualización disponible Y Mode=upgrade. Primero intenta cierre ordenado;
#     Stop-Process -Force solo se usa si ForceClose=true.
#   - No modifica nada en modo 'check'.
#
# Códigos de salida de WinGet usados SOLO como pista (validar en el host real):
#   -1978335212 (0x8A150014) = sin coincidencias
#   -1978335189 (0x8A15002B) = sin actualización aplicable
param(
  [Parameter(Mandatory)][string]$PackageId,
  [string]$Source = 'winget',
  [Parameter(Mandatory)][string]$Mode,
  [int]$TimeoutSeconds = 900,
  [string[]]$ProcessNames = @(),
  [string]$CloseProcesses = 'false',
  [string]$ForceClose = 'false',
  [int]$GraceSeconds = 20
)
$ErrorActionPreference = 'Stop'

# Ignora elementos vacíos (p. ej. una lista vacía serializada como cadena vacía).
$ProcessNames = @($ProcessNames | Where-Object { $_ -and "$_".Trim() })

# win_powershell marca changed=true por defecto; se activa solo si hay evidencia de cambio.
$Ansible.Changed = $false

$RC_NO_MATCH  = -1978335212
$RC_NO_UPDATE = -1978335189

function ConvertTo-Flag {
  param([string]$Value)
  return ("$Value" -match '^(?i:true|1|yes)$')
}

function Find-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  # El alias MSIX no está en PATH en sesiones no interactivas; requiere privilegios de admin.
  $c = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
       Sort-Object FullName -Descending | Select-Object -First 1
  if ($c) { return $c.FullName }
  return $null
}

function Invoke-Winget {
  param([string]$Exe, [string[]]$WgArgs, [int]$Timeout)
  $o = [IO.Path]::GetTempFileName()
  $e = [IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList $WgArgs -NoNewWindow -PassThru `
           -RedirectStandardOutput $o -RedirectStandardError $e
    $null = $p.Handle   # necesario en PS 5.1 para poder leer ExitCode
    $timedOut = -not $p.WaitForExit($Timeout * 1000)
    if ($timedOut) { try { $p.Kill() } catch { } }
    [pscustomobject]@{
      args      = ($WgArgs -join ' ')
      rc        = $(if ($timedOut) { $null } else { $p.ExitCode })
      timed_out = $timedOut
      stdout    = [IO.File]::ReadAllText($o, [Text.Encoding]::UTF8)
      stderr    = [IO.File]::ReadAllText($e, [Text.Encoding]::UTF8)
    }
  } finally {
    Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
  }
}

function Stop-AppProcesses {
  param([string[]]$Names, [bool]$Force, [int]$Grace)
  $info = [ordered]@{ found = @(); closed_gracefully = @(); force_killed = @(); still_running = @() }
  $procs = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return $info }
  $info.found = @($procs | ForEach-Object { "$($_.ProcessName)#$($_.Id)" })

  # 1) Cierre ordenado (CloseMainWindow). Puede no surtir efecto en procesos de otra sesión.
  foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch { } }
  $deadline = (Get-Date).AddSeconds($Grace)
  do {
    Start-Sleep -Seconds 1
    $alive = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  } while ($alive.Count -gt 0 -and (Get-Date) -lt $deadline)
  $aliveIds = @($alive | ForEach-Object { $_.Id })
  $info.closed_gracefully = @($procs | Where-Object { $aliveIds -notcontains $_.Id } |
                              ForEach-Object { "$($_.ProcessName)#$($_.Id)" })

  # 2) Cierre forzado SOLO si se pidió explícitamente (puede perder trabajo sin guardar).
  if ($alive.Count -gt 0 -and $Force) {
    foreach ($p in $alive) {
      try {
        Stop-Process -Id $p.Id -Force -ErrorAction Stop
        $info.force_killed += "$($p.ProcessName)#$($p.Id)"
      } catch { }
    }
    Start-Sleep -Seconds 2
    $alive = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
  }
  $info.still_running = @($alive | ForEach-Object { "$($_.ProcessName)#$($_.Id)" })
  return $info
}

$res = [ordered]@{
  id             = $PackageId
  source         = $Source
  mode           = $Mode
  winget_path    = $null
  winget_version = $null
  classification = 'script_error'
  error          = ''
}

try {
  # Validación de entrada: evita que un ID o fuente mal formados se interpreten como opciones.
  if ($Mode -ne 'check' -and $Mode -ne 'upgrade') { throw "Mode inválido: $Mode" }
  if ($PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { throw "PackageId inválido: $PackageId" }
  if ($Source -notmatch '^(winget|msstore)$') { throw "Source inválido: $Source" }
  foreach ($n in $ProcessNames) {
    if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._\-]*$') { throw "Nombre de proceso inválido: $n" }
  }

  $wg = Find-Winget
  $res.winget_path = $wg
  if (-not $wg) {
    $res.classification = 'winget_not_found'
  } else {
    $ver = Invoke-Winget $wg @('--version') $TimeoutSeconds
    $res.winget_version = "$($ver.stdout)".Trim()

    $common = @('--id', $PackageId, '--exact', '--source', $Source, '--accept-source-agreements')

    # 1) ¿Instalado con ese ID?  2) ¿Hay actualización?
    $res.before = Invoke-Winget $wg (@('list') + $common) $TimeoutSeconds
    $res.check  = Invoke-Winget $wg (@('list', '--upgrade-available') + $common) $TimeoutSeconds

    if ($res.before.timed_out -or $res.check.timed_out) {
      $res.classification = 'timeout'
    } elseif ($res.before.rc -eq $RC_NO_MATCH) {
      $res.classification = 'not_installed'
    } elseif ($res.before.rc -ne 0) {
      $res.classification = 'other_rc'
    } elseif ($res.check.rc -eq $RC_NO_MATCH) {
      $res.classification = 'up_to_date'
    } elseif ($res.check.rc -ne 0) {
      $res.classification = 'other_rc'
    } else {
      $res.classification = 'update_available'
    }

    # 3) Solo en modo upgrade y solo si hay actualización para ESTE id.
    if ($Mode -eq 'upgrade' -and $res.classification -eq 'update_available') {
      $blocked = $false
      if ((ConvertTo-Flag $CloseProcesses) -and $ProcessNames.Count -gt 0) {
        $res.processes = Stop-AppProcesses -Names $ProcessNames -Force (ConvertTo-Flag $ForceClose) -Grace $GraceSeconds
        if ($res.processes.still_running.Count -gt 0) {
          $blocked = $true
          $res.classification = 'blocked_by_process'
        }
      }
      if (-not $blocked) {
        $res.upgrade = Invoke-Winget $wg (@('upgrade') + $common + @('--silent', '--disable-interactivity', '--accept-package-agreements')) $TimeoutSeconds
        if ($res.upgrade.timed_out) {
          $res.classification = 'timeout'
        } else {
          # Verificación posterior independiente (no depende del texto de WinGet).
          $res.after      = Invoke-Winget $wg (@('list') + $common) $TimeoutSeconds
          $res.post_check = Invoke-Winget $wg (@('list', '--upgrade-available') + $common) $TimeoutSeconds
          if ($res.upgrade.rc -eq 0 -and $res.post_check.rc -eq $RC_NO_MATCH) {
            $res.classification = 'upgraded'
            $Ansible.Changed = $true
          } elseif ($res.upgrade.rc -eq 0 -and $res.post_check.rc -eq 0) {
            $res.classification = 'still_outdated'
          } elseif ($res.upgrade.rc -eq 0) {
            $res.classification = 'upgrade_unverified'
          } elseif ($res.upgrade.rc -eq $RC_NO_UPDATE) {
            $res.classification = 'up_to_date'
          } else {
            $res.classification = 'other_rc'
          }
        }
      }
    }
  }
} catch {
  $res.classification = 'script_error'
  $res.error = $_.Exception.Message
}

$Ansible.Result = $res