# Test-UpdatePrerequisites.ps1
#
# Comprobaciones previas de SOLO LECTURA para el gestor de actualizaciones. No instala,
# no descarga, no inicia ni detiene servicios y no escribe en el equipo (salvo archivos
# temporales de WinGet, que se eliminan). Se ejecuta con ansible.windows.win_powershell
# (variable $Ansible disponible). Compatible con Windows PowerShell 5.1: sin operadores
# ni cmdlets exclusivos de PowerShell 7.
#
# Cada comprobación produce un objeto { id, classification (ok|warn|fail), detail, data }.
# No se registran contraseñas, tokens ni la URL del servidor WSUS (solo si existe la política).
param(
  [double]$MinFreeGb = 10,
  [string]$MinPsVersion = '5.1',
  [int]$WingetTimeout = 90,
  [string]$RequireWinget = 'false'
)
$ErrorActionPreference = 'Stop'

# win_powershell marca changed=true por defecto; este script nunca cambia nada.
$Ansible.Changed = $false

$checks = New-Object System.Collections.ArrayList

function ConvertTo-Flag {
  param([string]$Value)
  return ("$Value" -match '^(?i:true|1|yes)$')
}

function Add-Check {
  param([string]$Id, [string]$Status, [string]$Detail, $Data = $null)
  [void]$checks.Add([pscustomobject]@{
    id             = $Id
    classification = $Status
    detail         = $Detail
    data           = $Data
  })
}

function Get-RegValue {
  param([string]$Path, [string]$Name)
  try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Limit-Text {
  param([string]$Text, [int]$Max = 1500)
  if ($null -eq $Text) { return '' }
  if ($Text.Length -le $Max) { return $Text }
  return $Text.Substring(0, $Max) + '...[truncado]'
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
      stdout    = Limit-Text ([IO.File]::ReadAllText($o, [Text.Encoding]::UTF8))
      stderr    = Limit-Text ([IO.File]::ReadAllText($e, [Text.Encoding]::UTF8))
    }
  } finally {
    Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
  }
}

# 1) Versión efectiva de PowerShell (la que usa el módulo de Ansible, no la de tu sesión local)
try {
  $psv = $PSVersionTable.PSVersion
  $edition = 'Desktop'
  if ($PSVersionTable.PSEdition) { $edition = "$($PSVersionTable.PSEdition)" }
  $cur = New-Object System.Version($psv.Major, $psv.Minor)
  $st = 'ok'
  if ($cur -lt [version]$MinPsVersion) { $st = 'fail' }
  Add-Check 'powershell' $st "PowerShell $psv ($edition)" @{ version = "$psv"; edition = $edition; min_required = $MinPsVersion }
} catch {
  Add-Check 'powershell' 'fail' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 2) Identidad y privilegios (win_updates exige pertenecer al grupo Administradores)
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $st = 'fail'
  if ($isAdmin) { $st = 'ok' }
  Add-Check 'identity_admin' $st "Identidad: $($id.Name); administrador: $isAdmin" @{
    identity = "$($id.Name)"; is_admin = [bool]$isAdmin; is_system = [bool]$id.IsSystem; auth_type = "$($id.AuthenticationType)"
  }
} catch {
  Add-Check 'identity_admin' 'fail' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 3) Sistema operativo. OJO: ProductName sigue diciendo "Windows 10" en algunas builds de
#    Windows 11; la referencia fiable es el número de compilación (>= 22000 = Windows 11).
try {
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build = [int]$cv.CurrentBuild
  $disp = "$($cv.DisplayVersion)"
  if (-not $disp) { $disp = "$($cv.ReleaseId)" }
  $st = 'warn'
  if ($build -ge 22000) { $st = 'ok' }
  Add-Check 'os' $st "Windows build $build.$($cv.UBR) (versión $disp)" @{
    build = $build; ubr = "$($cv.UBR)"; display_version = $disp; product_name = "$($cv.ProductName)"; is_windows_11 = ($build -ge 22000)
  }
} catch {
  Add-Check 'os' 'warn' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 4) Servicios. Un wuauserv detenido con inicio Manual/Automático es NORMAL (arranca bajo
#    demanda); solo se marca fallo si está deshabilitado o no existe.
$svcDefs = @(
  @{ n = 'wuauserv'; crit = $true },
  @{ n = 'bits';     crit = $false },
  @{ n = 'cryptsvc'; crit = $false },
  @{ n = 'WinRM';    crit = $false }
)
$svcData = [ordered]@{}
$svcStatus = 'ok'
foreach ($d in $svcDefs) {
  $bad = $false
  try {
    $s = Get-Service -Name $d.n -ErrorAction Stop
    $svcData[$d.n] = [ordered]@{ status = "$($s.Status)"; start_type = "$($s.StartType)" }
    if ("$($s.StartType)" -eq 'Disabled') { $bad = $true }
  } catch {
    $svcData[$d.n] = [ordered]@{ status = 'not_found'; start_type = '' }
    $bad = $true
  }
  if ($bad) {
    if ($d.crit) { $svcStatus = 'fail' } elseif ($svcStatus -ne 'fail') { $svcStatus = 'warn' }
  }
}
$svcText = @($svcData.Keys | ForEach-Object { "$_=$($svcData[$_].status)/$($svcData[$_].start_type)" }) -join ', '
Add-Check 'services' $svcStatus "Servicios: $svcText" $svcData

# 5) Reinicio pendiente. PendingFileRenameOperations es muy frecuente y no se trata como
#    advertencia (solo se informa en 'data').
try {
  $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $wuReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  $pfr = $null -ne (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations')
  $st = 'ok'
  if ($cbs -or $wuReboot) { $st = 'warn' }
  Add-Check 'pending_reboot' $st "CBS=$cbs; WindowsUpdate=$wuReboot; PendingFileRename=$pfr" @{
    cbs_reboot_pending = [bool]$cbs; windows_update_reboot_required = [bool]$wuReboot; pending_file_rename = [bool]$pfr
  }
} catch {
  Add-Check 'pending_reboot' 'warn' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 6) Espacio libre en la unidad del sistema
try {
  $drv = $env:SystemDrive
  if (-not $drv) { $drv = 'C:' }
  $di = New-Object System.IO.DriveInfo($drv)
  $freeGb = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
  $st = 'ok'
  if ($freeGb -lt $MinFreeGb) { $st = 'fail' }
  Add-Check 'disk_free' $st "$drv libre: $freeGb GB (mínimo $MinFreeGb GB)" @{ drive = $drv; free_gb = $freeGb; min_free_gb = $MinFreeGb }
} catch {
  Add-Check 'disk_free' 'warn' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 7) Políticas de Windows Update (solo lectura). No se registra la URL de WSUS.
try {
  $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $auPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  $wsus = [bool](Get-RegValue $wuPol 'WUServer')
  $useWu = Get-RegValue $auPol 'UseWUServer'
  $disableWu = Get-RegValue $wuPol 'DisableWindowsUpdateAccess'
  $noAuto = Get-RegValue $auPol 'NoAutoUpdate'
  $st = 'ok'
  if ($disableWu -eq 1) { $st = 'warn' }
  Add-Check 'update_policy' $st "WSUS por política: $wsus; UseWUServer=$useWu; DisableWindowsUpdateAccess=$disableWu; NoAutoUpdate=$noAuto" @{
    wsus_configured = $wsus; use_wu_server = $useWu; disable_windows_update_access = $disableWu; no_auto_update = $noAuto
  }
} catch {
  Add-Check 'update_policy' 'warn' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 8) Sesión interactiva (informativo; win_updates puede requerir become si falla por falta de usuario)
try {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem
  $has = -not [string]::IsNullOrEmpty("$($cs.UserName)")
  Add-Check 'interactive_user' 'ok' "Hay un usuario con sesión interactiva: $has" @{ interactive_user_present = $has }
} catch {
  Add-Check 'interactive_user' 'warn' ("No se pudo evaluar: " + $_.Exception.Message)
}

# 9) WinGet bajo ESTA identidad/sesión (lo que realmente verán los roles de aplicaciones)
function Format-Rc {
  param($Call)
  if ($Call.timed_out) { return 'timeout' }
  return "$($Call.rc)"
}
$wgFailStatus = 'warn'
if (ConvertTo-Flag $RequireWinget) { $wgFailStatus = 'fail' }
try {
  $wg = Find-Winget
  if (-not $wg) {
    Add-Check 'winget' $wgFailStatus 'winget.exe no se encuentra para esta identidad/sesión' @{ path = $null }
  } else {
    $ver   = Invoke-Winget $wg @('--version') $WingetTimeout
    $src   = Invoke-Winget $wg @('source', 'list') $WingetTimeout
    $probe = Invoke-Winget $wg @('list', '--count', '1', '--accept-source-agreements') $WingetTimeout
    $st = 'ok'
    if ($ver.timed_out -or $src.timed_out -or $probe.timed_out) { $st = $wgFailStatus }
    elseif ($ver.rc -ne 0 -or $probe.rc -ne 0) { $st = $wgFailStatus }
    elseif ($src.rc -ne 0) { $st = 'warn' }
    $vtxt = ("$($ver.stdout)").Trim()
    Add-Check 'winget' $st "winget $vtxt; version rc=$(Format-Rc $ver); source list rc=$(Format-Rc $src); sondeo list rc=$(Format-Rc $probe)" @{
      path = $wg; version = $vtxt; version_call = $ver; source_list_call = $src; probe_call = $probe
    }
  }
} catch {
  Add-Check 'winget' $wgFailStatus ("No se pudo evaluar: " + $_.Exception.Message)
}

$Ansible.Result = [ordered]@{
  computer = "$env:COMPUTERNAME"
  checks   = @($checks.ToArray())
}