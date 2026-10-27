#Requires -Version 5.1
<#
    Z. Optimizer v1.1
    Optimizador para Windows 11 (24H2 / 25H2 / 26H2)

    Módulos:
      · Z. Plan       — plan de energía propio basado en Máximo rendimiento
      · Registro      — .reg verificados (aplicar / revertir / exportar)
      · Optimizador   — privacidad, telemetría, anuncios, limpieza. Modo Normal o Gaming
      · Juegos        — perfiles de Fortnite (modo Rendimiento DX11) aplicados al GameUserSettings.ini
      · Restaurar     — deshace todo lo anterior

    Todo lo que cambia queda registrado en %ProgramData%\ZOptimizer para poder revertirlo.

    Copyright (C) 2026 zevi
    SPDX-License-Identifier: GPL-3.0-or-later
    Este programa es software libre: puedes redistribuirlo y/o modificarlo bajo los términos de la
    GNU General Public License publicada por la Free Software Foundation, versión 3 o posterior.
    Se distribuye SIN NINGUNA GARANTÍA. Consulta el archivo LICENSE.
#>

# ---------------------------------------------------------------------------
#  Arranque: administrador + STA (necesario para WPF)
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Verb RunAs
    } catch {}
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$sync = [hashtable]::Synchronized(@{
    Log    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Busy   = $false
    PS     = $null
    RS     = $null
    Handle = $null
})

# ===========================================================================
#  MOTOR  (se ejecuta en un hilo aparte para no congelar la ventana)
# ===========================================================================
$EngineCode = {

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$ZRoot = Join-Path $env:ProgramData 'ZOptimizer'
if (-not (Test-Path $ZRoot)) { New-Item -ItemType Directory -Path $ZRoot -Force | Out-Null }
$RegAppliedFile = Join-Path $ZRoot 'reg-applied.txt'

$script:ZDryRun    = $false
$script:Journal    = New-Object System.Collections.Generic.List[object]
$script:JournalDir = $null

$Guid_Ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$Guid_High     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$Guid_Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$GuidRx        = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
$ZPlanName     = 'Z. Plan'

# ---------------------------------------------------------------- utilidades
function Write-ZLog {
    param([string]$Msg, [ValidateSet('info','ok','warn','err','head','dry')][string]$Level = 'info')
    $pfx = @{ info = '    '; ok = '  ✔ '; warn = '  ⚠ '; err = '  ✖ '; head = '▶ '; dry = '  · ' }[$Level]
    $sync.Log.Enqueue(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $pfx, $Msg))
}

function Test-IsLaptop { [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) }

function Get-FreeGB {
    $d = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($d) { [math]::Round($d.Free / 1GB, 2) } else { 0 }
}

function New-ZRestorePoint([string]$Description) {
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-ZLog 'Punto de restauración creado.' ok
        return $true
    } catch {
        Write-ZLog "No se pudo crear el punto de restauración: $($_.Exception.Message)" warn
        return $false
    }
}

# ---------------------------------------------------------------- journal
function Start-Journal([string]$Label) {
    $script:Journal    = New-Object System.Collections.Generic.List[object]
    $script:JournalDir = Join-Path $ZRoot ('journals\{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label)
    if (-not $script:ZDryRun) { New-Item -ItemType Directory -Path $script:JournalDir -Force | Out-Null }
}
function Save-Journal {
    if ($script:ZDryRun -or -not $script:JournalDir) { return }
    ConvertTo-Json -InputObject @($script:Journal.ToArray()) -Depth 6 |
        Set-Content -LiteralPath (Join-Path $script:JournalDir 'journal.json') -Encoding UTF8
}
function Add-JournalEntry([hashtable]$Entry) { $script:Journal.Add([pscustomobject]$Entry) }

function Get-Journals {
    $dir = Join-Path $ZRoot 'journals'
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem -LiteralPath $dir -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'journal.json') } |
        Sort-Object Name -Descending
}

function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','Binary','MultiString')][string]$Type = 'DWord'
    )
    if ($script:ZDryRun) { Write-ZLog "$Path\$Name = $Value" dry; return }
    try {
        $existed = $false; $old = $null; $oldType = $null
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path
            if ($key.GetValueNames() -contains $Name) {
                $existed = $true
                $old     = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $oldType = $key.GetValueKind($Name).ToString()
                if ($oldType -eq $Type -and (@($old) -join ',') -eq (@($Value) -join ',')) { return }
            }
        } else {
            New-Item -Path $Path -Force | Out-Null
        }
        Add-JournalEntry @{ Kind = 'Reg'; Path = $Path; Name = $Name; Existed = $existed; OldValue = $old; OldType = $oldType }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch {
        Write-ZLog "No se pudo escribir $Path\$Name : $($_.Exception.Message)" warn
    }
}

function Set-ServiceStart([string]$Name, [ValidateSet('Automatic','Manual','Disabled')][string]$Mode) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    $map = @{ Automatic = 2; Manual = 3; Disabled = 4 }
    Set-Reg -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start' -Value $map[$Mode]
    if ($script:ZDryRun) { return }
    if ($Mode -eq 'Disabled' -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Write-ZLog "Servicio $Name → $Mode" ok
}

function Disable-ZSchedTask([string]$TaskPath, [string]$TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t -or $t.State -eq 'Disabled') { return }
    if ($script:ZDryRun) { Write-ZLog "Desactivar tarea $TaskName" dry; return }
    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Add-JournalEntry @{ Kind = 'Task'; Path = $TaskPath; Name = $TaskName }
        Write-ZLog "Tarea desactivada: $TaskName" ok
    } catch { Write-ZLog "No se pudo desactivar $TaskName" warn }
}

function Restore-Journal([string]$Dir) {
    $jf = Join-Path $Dir 'journal.json'
    if (-not (Test-Path $jf)) { Write-ZLog 'No se encontró el journal.' err; return }
    Write-ZLog "Restaurando $(Split-Path $Dir -Leaf)" head
    $entries = @(Get-Content -LiteralPath $jf -Raw | ConvertFrom-Json)
    [array]::Reverse($entries)
    $n = 0
    foreach ($e in $entries) {
        try {
            switch ($e.Kind) {
                'Reg' {
                    if ($e.Existed) {
                        $v = switch ($e.OldType) {
                            'DWord'       { [int]$e.OldValue }
                            'QWord'       { [long]$e.OldValue }
                            'Binary'      { [byte[]]@($e.OldValue) }
                            'MultiString' { [string[]]@($e.OldValue) }
                            default       { [string]$e.OldValue }
                        }
                        if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                        New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $v -PropertyType $e.OldType -Force | Out-Null
                    } elseif (Test-Path -LiteralPath $e.Path) {
                        Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                }
                'Key'       { Remove-Item -LiteralPath $e.Path -Recurse -Force -ErrorAction SilentlyContinue }
                'Task'      { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction SilentlyContinue | Out-Null }
                'Power'     { powercfg /setactive $e.OldValue | Out-Null; Write-ZLog 'Plan de energía anterior reactivado.' ok }
                'Hibernate' { powercfg /hibernate on | Out-Null; Write-ZLog 'Hibernación reactivada.' ok }
                'Appx'      { Write-ZLog "App eliminada (reinstálala desde Microsoft Store si la quieres): $($e.Name)" info }
            }
            $n++
        } catch { Write-ZLog "Fallo restaurando $($e.Path)\$($e.Name)" warn }
    }
    Rename-Item -LiteralPath $Dir -NewName ((Split-Path $Dir -Leaf) + '-restaurado') -ErrorAction SilentlyContinue
    Write-ZLog "Restauración completada ($n cambios). Reinicia para aplicarlo todo." ok
}

# ===========================================================================
#  Z. PLAN
# ===========================================================================
function Get-PowerPlans {
    foreach ($l in (powercfg /list)) {
        if ($l -match "$GuidRx\s+\((.+)\)(\s*\*)?") {
            [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2]; Active = [bool]$Matches[3] }
        }
    }
}

function Get-ActivePlanGuid {
    $l = (powercfg /getactivescheme) -join ''
    if ($l -match $GuidRx) { $Matches[1] } else { $null }
}

function Install-ZPlan([hashtable]$O) {
    if (-not $O) { $O = @{} }
    Write-ZLog 'Creando Z. Plan' head
    $laptop = Test-IsLaptop
    if ($laptop) { Write-ZLog 'Portátil: Z. Plan solo cambia los valores con corriente (AC). Con batería se mantiene el comportamiento base.' warn }

    foreach ($p in @(Get-PowerPlans | Where-Object Name -eq $ZPlanName)) {
        if ($p.Active) { powercfg /setactive $Guid_Balanced | Out-Null }
        powercfg /delete $p.Guid | Out-Null
        Write-ZLog 'Versión anterior de Z. Plan eliminada.'
    }

    $g = $null; $baseUsed = $null
    foreach ($base in @($Guid_Ultimate, $Guid_High, $Guid_Balanced)) {
        $out = (powercfg /duplicatescheme $base 2>&1) | Out-String
        if ($LASTEXITCODE -eq 0 -and $out -match $GuidRx) { $g = $Matches[1]; $baseUsed = $base; break }
    }
    if (-not $g) { Write-ZLog 'No se pudo crear el plan (equipo con Modern Standby que solo permite Equilibrado).' err; return }
    $baseLabel = @{ $Guid_Ultimate = 'Máximo rendimiento'; $Guid_High = 'Alto rendimiento'; $Guid_Balanced = 'Equilibrado' }[$baseUsed]
    Write-ZLog "Base: $baseLabel" ok

    powercfg /changename $g $ZPlanName 'Plan de Z. Optimizer: CPU al 100 %, sin aparcamiento de núcleos ni ahorro en PCIe, USB y disco. C-states activos.' | Out-Null

    $settings = New-Object System.Collections.Generic.List[object]
    $settings.Add(@('SUB_PROCESSOR', 'PROCTHROTTLEMIN', 100, 'Estado mínimo del procesador: 100 %'))
    $settings.Add(@('SUB_PROCESSOR', 'PROCTHROTTLEMAX', 100, 'Estado máximo del procesador: 100 %'))
    $settings.Add(@('SUB_PROCESSOR', 'CPMINCORES', 100, 'Aparcamiento de núcleos desactivado'))
    $settings.Add(@('SUB_PROCESSOR', 'PERFBOOSTMODE', 2, 'Turbo: agresivo'))
    $settings.Add(@('SUB_PROCESSOR', 'PERFEPP', 0, 'Preferencia de energía: máximo rendimiento'))
    $settings.Add(@('SUB_PCIEXPRESS', 'ASPM', 0, 'PCI Express sin ahorro de energía (ASPM)'))
    $settings.Add(@('SUB_DISK', 'DISKIDLE', 0, 'El disco no se apaga'))
    $settings.Add(@('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0, 'USB sin suspensión selectiva'))
    if ($O.Wifi)                     { $settings.Add(@('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', 0, 'Wi-Fi a máximo rendimiento')) }
    if ($O.NoSleep -and -not $laptop) { $settings.Add(@('SUB_SLEEP', 'STANDBYIDLE', 0, 'Sin suspensión automática')) }

    foreach ($s in $settings) {
        $null = powercfg /setacvalueindex $g $s[0] $s[1] $s[2] 2>&1
        if ($LASTEXITCODE -eq 0) { Write-ZLog $s[3] ok } else { Write-ZLog "$($s[3]) — no disponible en este equipo" warn }
    }

    # CPUs híbridas (Intel 12.ª gen+): mismos ajustes para los núcleos E
    $eOk = 0
    foreach ($s in @(@('PROCTHROTTLEMIN1', 100), @('CPMINCORES1', 100), @('PERFEPP1', 0))) {
        $null = powercfg /setacvalueindex $g SUB_PROCESSOR $s[0] $s[1] 2>&1
        if ($LASTEXITCODE -eq 0) { $eOk++ }
    }
    if ($eOk) { Write-ZLog 'Núcleos de eficiencia (E-cores) ajustados igual.' ok }

    if ($O.Hibernate) {
        powercfg /hibernate off | Out-Null
        Write-ZLog 'Hibernación desactivada (libera hiberfil.sys; desactiva el inicio rápido).' ok
    }
    if ($O.Activate -ne $false) {
        powercfg /setactive $g | Out-Null
        Write-ZLog 'Z. Plan activado.' ok
    }
}

function Remove-ZPlan {
    $plans = @(Get-PowerPlans | Where-Object Name -eq $ZPlanName)
    if (-not $plans) { Write-ZLog 'No hay ningún Z. Plan instalado.' warn; return }
    foreach ($p in $plans) {
        if ($p.Active) { powercfg /setactive $Guid_Balanced | Out-Null; Write-ZLog 'Equilibrado activado.' ok }
        powercfg /delete $p.Guid | Out-Null
    }
    Write-ZLog 'Z. Plan eliminado.' ok
}

# ===========================================================================
#  .REG VERIFICADOS (funcionan en 24H2 / 25H2 / 26H2)
# ===========================================================================
$RegTweaks = @(
[pscustomobject]@{ Id='mouse'; Cat='Entrada'; Rec=$true
  Name='Ratón sin aceleración'
  Desc='Quita "Mejorar precisión del puntero". El movimiento del ratón pasa a ser 1:1, ideal para apuntar.'
  Apply=@'
[HKEY_CURRENT_USER\Control Panel\Mouse]
"MouseSpeed"="0"
"MouseThreshold1"="0"
"MouseThreshold2"="0"
'@
  Revert=@'
[HKEY_CURRENT_USER\Control Panel\Mouse]
"MouseSpeed"="1"
"MouseThreshold1"="6"
"MouseThreshold2"="10"
'@ }
,
[pscustomobject]@{ Id='hotkeys'; Cat='Entrada'; Rec=$true
  Name='Sin atajos de Teclas especiales, filtro y alternancia'
  Desc='Evita que Shift ×5 o mantener Shift 8 s te saque de la partida o active el rebote de teclas.'
  Apply=@'
[HKEY_CURRENT_USER\Control Panel\Accessibility\StickyKeys]
"Flags"="506"

[HKEY_CURRENT_USER\Control Panel\Accessibility\Keyboard Response]
"Flags"="122"

[HKEY_CURRENT_USER\Control Panel\Accessibility\ToggleKeys]
"Flags"="58"
'@
  Revert=@'
[HKEY_CURRENT_USER\Control Panel\Accessibility\StickyKeys]
"Flags"="510"

[HKEY_CURRENT_USER\Control Panel\Accessibility\Keyboard Response]
"Flags"="126"

[HKEY_CURRENT_USER\Control Panel\Accessibility\ToggleKeys]
"Flags"="62"
'@ }
,
[pscustomobject]@{ Id='keyrepeat'; Cat='Entrada'; Rec=$false
  Name='Repetición de teclas más rápida'
  Desc='Retraso de repetición mínimo y velocidad máxima al mantener una tecla. Cuestión de gustos.'
  Apply=@'
[HKEY_CURRENT_USER\Control Panel\Keyboard]
"KeyboardDelay"="0"
"KeyboardSpeed"="31"
'@
  Revert=@'
[HKEY_CURRENT_USER\Control Panel\Keyboard]
"KeyboardDelay"="1"
"KeyboardSpeed"="31"
'@ }
,
[pscustomobject]@{ Id='gamedvr'; Cat='Juegos'; Rec=$true
  Name='Sin grabación de Game Bar en segundo plano'
  Desc='Desactiva Game DVR y la captura en segundo plano, que sí consumen GPU mientras juegas.'
  Apply=@'
[HKEY_CURRENT_USER\System\GameConfigStore]
"GameDVR_Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AppCaptureEnabled"=dword:00000000
"HistoricalCaptureEnabled"=dword:00000000
'@
  Revert=@'
[HKEY_CURRENT_USER\System\GameConfigStore]
"GameDVR_Enabled"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AppCaptureEnabled"=dword:00000001
"HistoricalCaptureEnabled"=-
'@ }
,
[pscustomobject]@{ Id='gamemode'; Cat='Juegos'; Rec=$true
  Name='Modo de juego activado'
  Desc='Windows prioriza el juego en primer plano y aplaza las actualizaciones mientras juegas.'
  Apply=@'
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"AutoGameModeEnabled"=dword:00000001
"AllowAutoGameMode"=dword:00000001
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"AutoGameModeEnabled"=-
"AllowAutoGameMode"=-
'@ }
,
[pscustomobject]@{ Id='hags'; Cat='Juegos'; Rec=$true
  Name='Programación de GPU acelerada por hardware (HAGS)'
  Desc='Necesaria para DLSS Frame Generation y suele reducir algo la latencia. Requiere reiniciar.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers]
"HwSchMode"=dword:00000002
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers]
"HwSchMode"=dword:00000001
'@ }
,
[pscustomobject]@{ Id='mpo'; Cat='Juegos'; Rec=$false
  Name='Desactivar MPO (Multiplane Overlay)'
  Desc='SOLO si tienes pantallazos negros, parpadeos o tirones con varios monitores (muy típico en AMD con Fortnite en modo Rendimiento).'
  Apply=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Dwm]
"OverlayTestMode"=dword:00000005
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Dwm]
"OverlayTestMode"=-
'@ }
,
[pscustomobject]@{ Id='powerthrottle'; Cat='Rendimiento'; Rec=$true
  Name='Sin Power Throttling'
  Desc='Windows deja de frenar los procesos en segundo plano (Discord, OBS…). En portátil gasta algo más de batería.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling]
"PowerThrottlingOff"=dword:00000001
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling]
"PowerThrottlingOff"=-
'@ }
,
[pscustomobject]@{ Id='prio26'; Cat='Rendimiento'; Rec=$false
  Name='Win32PrioritySeparation = 0x26'
  Desc='Turnos cortos y variables con más prioridad para la ventana activa. Ajuste real, pero el efecto en juegos es mínimo y discutido.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl]
"Win32PrioritySeparation"=dword:00000026
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl]
"Win32PrioritySeparation"=dword:00000002
'@ }
,
[pscustomobject]@{ Id='network'; Cat='Rendimiento'; Rec=$false
  Name='Sin limitación de red multimedia'
  Desc='NetworkThrottlingIndex desactivado y SystemResponsiveness a 10. Inofensivo, pero el efecto es pequeño.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"NetworkThrottlingIndex"=dword:ffffffff
"SystemResponsiveness"=dword:0000000a
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"NetworkThrottlingIndex"=dword:0000000a
"SystemResponsiveness"=dword:00000014
'@ }
,
[pscustomobject]@{ Id='startup'; Cat='Rendimiento'; Rec=$true
  Name='Sin retraso de las apps de inicio'
  Desc='Windows añade un retraso artificial a los programas de inicio. Esto lo quita.'
  Apply=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize]
"StartupDelayInMSec"=dword:00000000
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize]
"StartupDelayInMSec"=-
'@ }
,
[pscustomobject]@{ Id='animations'; Cat='Rendimiento'; Rec=$false
  Name='Menos animaciones'
  Desc='Menús más rápidos, sin animación al minimizar ni en la barra de tareas. Se nota más en equipos modestos.'
  Apply=@'
[HKEY_CURRENT_USER\Control Panel\Desktop]
"MenuShowDelay"="100"

[HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics]
"MinAnimate"="0"

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAnimations"=dword:00000000
'@
  Revert=@'
[HKEY_CURRENT_USER\Control Panel\Desktop]
"MenuShowDelay"="400"

[HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics]
"MinAnimate"="1"

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAnimations"=dword:00000001
'@ }
,
[pscustomobject]@{ Id='edge'; Cat='Rendimiento'; Rec=$true
  Name='Edge no se queda en segundo plano'
  Desc='Desactiva Startup Boost y el modo en segundo plano de Edge. Libera RAM y CPU.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge]
"StartupBoostEnabled"=dword:00000000
"BackgroundModeEnabled"=dword:00000000
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge]
"StartupBoostEnabled"=-
"BackgroundModeEnabled"=-
'@ }
,
[pscustomobject]@{ Id='drivers'; Cat='Sistema'; Rec=$false
  Name='Windows Update no instala drivers'
  Desc='Útil si gestionas tú los drivers de NVIDIA/AMD y no quieres que Windows los sustituya.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching]
"SearchOrderConfig"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate]
"ExcludeWUDriversInQualityUpdate"=dword:00000001
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching]
"SearchOrderConfig"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate]
"ExcludeWUDriversInQualityUpdate"=-
'@ }
,
[pscustomobject]@{ Id='websearch'; Cat='Interfaz'; Rec=$true
  Name='Búsqueda sin resultados de Bing'
  Desc='La búsqueda de Inicio solo busca en tu PC: más rápida y sin web.'
  Apply=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search]
"BingSearchEnabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search]
"BingSearchEnabled"=-

[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=-
'@ }
,
[pscustomobject]@{ Id='widgets'; Cat='Interfaz'; Rec=$true
  Name='Sin Widgets ni noticias'
  Desc='Quita el panel de Widgets y su proceso en segundo plano.'
  Apply=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh]
"AllowNewsAndInterests"=dword:00000000
'@
  Revert=@'
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh]
"AllowNewsAndInterests"=-
'@ }
,
[pscustomobject]@{ Id='ads'; Cat='Interfaz'; Rec=$true
  Name='Sin anuncios ni sugerencias'
  Desc='Sin apps sugeridas, consejos, recomendaciones en Inicio ni "termina de configurar tu dispositivo".'
  Apply=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"SilentInstalledAppsEnabled"=dword:00000000
"SystemPaneSuggestionsEnabled"=dword:00000000
"SoftLandingEnabled"=dword:00000000
"SubscribedContent-338388Enabled"=dword:00000000
"SubscribedContent-338389Enabled"=dword:00000000
"SubscribedContent-338393Enabled"=dword:00000000
"SubscribedContent-353694Enabled"=dword:00000000
"SubscribedContent-353696Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_IrisRecommendations"=dword:00000000
"ShowSyncProviderNotifications"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement]
"ScoobeSystemSettingEnabled"=dword:00000000
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"SilentInstalledAppsEnabled"=dword:00000001
"SystemPaneSuggestionsEnabled"=dword:00000001
"SoftLandingEnabled"=dword:00000001
"SubscribedContent-338388Enabled"=dword:00000001
"SubscribedContent-338389Enabled"=dword:00000001
"SubscribedContent-338393Enabled"=dword:00000001
"SubscribedContent-353694Enabled"=dword:00000001
"SubscribedContent-353696Enabled"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_IrisRecommendations"=-
"ShowSyncProviderNotifications"=-

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement]
"ScoobeSystemSettingEnabled"=-
'@ }
,
[pscustomobject]@{ Id='ai'; Cat='Interfaz'; Rec=$false
  Name='Sin Copilot, Recall ni Click to Do'
  Desc='Directivas oficiales para desactivar las funciones de IA de Windows.'
  Apply=@'
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI]
"DisableAIDataAnalysis"=dword:00000001
"AllowRecallEnablement"=dword:00000000
"DisableClickToDo"=dword:00000001
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI]
"DisableAIDataAnalysis"=-
"AllowRecallEnablement"=-
"DisableClickToDo"=-
'@ }
,
[pscustomobject]@{ Id='fileext'; Cat='Interfaz'; Rec=$true
  Name='Mostrar extensiones de archivo'
  Desc='Ves si un archivo es .exe, .reg, .ini… Más cómodo y más seguro.'
  Apply=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"HideFileExt"=dword:00000000
'@
  Revert=@'
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"HideFileExt"=dword:00000001
'@ }
,
[pscustomobject]@{ Id='classicmenu'; Cat='Interfaz'; Rec=$false
  Name='Menú contextual clásico'
  Desc='Clic derecho con el menú completo de Windows 10, sin pasar por "Mostrar más opciones".'
  Apply=@'
[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""
'@
  Revert=@'
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}]
'@ }
)

function Get-RegApplied {
    if (Test-Path $RegAppliedFile) { @(Get-Content -LiteralPath $RegAppliedFile | Where-Object { $_ }) } else { @() }
}
function Set-RegApplied([string[]]$Ids) {
    Set-Content -LiteralPath $RegAppliedFile -Value (@($Ids | Select-Object -Unique) -join "`r`n") -Encoding UTF8
}

function ConvertTo-RegFileText([string]$Body) {
    "Windows Registry Editor Version 5.00`r`n`r`n" + (($Body.Trim()) -replace "`r?`n", "`r`n") + "`r`n"
}

function Import-RegText([string]$Body) {
    $f = Join-Path $env:TEMP ('zopt-{0}.reg' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $f -Value (ConvertTo-RegFileText $Body) -Encoding Unicode
    $null = & reg.exe import $f 2>&1
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return ($code -eq 0)
}

function Invoke-RegTweaks([hashtable]$O) {
    $ids = @($O.Ids)
    if (-not $ids) { Write-ZLog 'No hay ningún .reg seleccionado.' warn; return }
    $apply = $O.Action -ne 'Revert'
    Write-ZLog ($(if ($apply) { 'Aplicando' } else { 'Revirtiendo' }) + " $($ids.Count) ajustes de registro") head
    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($a in (Get-RegApplied)) { $applied.Add($a) }
    foreach ($id in $ids) {
        $t = $RegTweaks | Where-Object Id -eq $id
        if (-not $t) { continue }
        $ok = Import-RegText $(if ($apply) { $t.Apply } else { $t.Revert })
        if ($ok) {
            if ($apply) { if (-not $applied.Contains($id)) { $applied.Add($id) } } else { [void]$applied.Remove($id) }
            Write-ZLog $t.Name ok
        } else { Write-ZLog "$($t.Name) — reg.exe devolvió un error" err }
    }
    Set-RegApplied $applied.ToArray()
    Write-ZLog 'Hecho. Algunos cambios necesitan cerrar sesión o reiniciar (HAGS, ratón, Explorador).' ok
}

function Export-RegTweaks([hashtable]$O) {
    $ids = @($O.Ids); if (-not $ids) { $ids = @($RegTweaks | ForEach-Object Id) }
    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('Z. Optimizer\reg-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path (Join-Path $dir 'revertir') -Force | Out-Null
    $i = 0
    foreach ($id in $ids) {
        $t = $RegTweaks | Where-Object Id -eq $id
        if (-not $t) { continue }
        $i++
        $safe = ($t.Name -replace '[\\/:*?"<>|]', '') -replace '\s+', ' '
        $file = '{0:D2} - {1}.reg' -f $i, $safe
        Set-Content -LiteralPath (Join-Path $dir $file)              -Value (ConvertTo-RegFileText $t.Apply)  -Encoding Unicode
        Set-Content -LiteralPath (Join-Path $dir "revertir\$file")   -Value (ConvertTo-RegFileText $t.Revert) -Encoding Unicode
    }
    Write-ZLog "$i archivos .reg exportados (con su versión para revertir) en: $dir" ok
    Start-Process explorer.exe $dir
}

# ===========================================================================
#  OPTIMIZADOR (Normal / Gaming)
# ===========================================================================
function Invoke-Optimizer([hashtable]$O) {
    $script:ZDryRun = [bool]$O.DryRun
    $gaming = $O.Mode -eq 'Gaming'
    Write-ZLog ("Optimizador · modo {0}{1}" -f $O.Mode, $(if ($script:ZDryRun) { ' · SIMULACIÓN' } else { '' })) head
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-ZLog "Windows $($cv.DisplayVersion) · build $($cv.CurrentBuild).$($cv.UBR)"
    Start-Journal $O.Mode
    $freeBefore = Get-FreeGB
    $laptop = Test-IsLaptop

    if ($O.RestorePoint -and -not $script:ZDryRun) { [void](New-ZRestorePoint 'Z. Optimizer: antes de optimizar') }

    # ---- Privacidad y telemetría (sin tocar Windows Update ni Defender)
    Write-ZLog 'Privacidad y telemetría' head
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    Set-Reg "$pol\DataCollection" 'AllowTelemetry' 1
    Set-Reg "$pol\DataCollection" 'DoNotShowFeedbackNotifications' 1
    Set-Reg "$pol\DataCollection" 'LimitDiagnosticLogCollection' 1
    Set-Reg "$pol\System" 'PublishUserActivities' 0
    Set-Reg "$pol\System" 'UploadUserActivities' 0
    Set-Reg "$pol\AdvertisingInfo" 'DisabledByGroupPolicy' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
    Set-ServiceStart 'DiagTrack' 'Disabled'
    Set-ServiceStart 'dmwappushservice' 'Disabled'
    foreach ($t in @(
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
        @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
        @('\Microsoft\Windows\Autochk\', 'Proxy'))) { Disable-ZSchedTask $t[0] $t[1] }
    Write-ZLog 'Telemetría al mínimo.' ok
    Save-Journal

    # ---- Anuncios e interfaz
    Write-ZLog 'Anuncios, sugerencias e interfaz' head
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','PreInstalledAppsEnabled',
                   'OemPreInstalledAppsEnabled','RotatingLockScreenOverlayEnabled','SubscribedContent-310093Enabled',
                   'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                   'SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled',
                   'SubscribedContent-353698Enabled') { Set-Reg $cdm $n 0 }
    Set-Reg "$pol\CloudContent" 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'Start_IrisRecommendations' 0
    Set-Reg $adv 'Start_AccountNotifications' 0
    Set-Reg $adv 'ShowSyncProviderNotifications' 0
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Write-ZLog 'Sin anuncios, sin Bing en la búsqueda, sin Widgets.' ok
    Save-Journal

    # ---- IA
    if ($O.DisableAI) {
        Write-ZLog 'Funciones de IA' head
        Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        Set-Reg "$pol\WindowsAI" 'DisableAIDataAnalysis' 1
        Set-Reg "$pol\WindowsAI" 'AllowRecallEnablement' 0
        Set-Reg "$pol\WindowsAI" 'DisableClickToDo' 1
        Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        Set-Reg $adv 'ShowCopilotButton' 0
        Write-ZLog 'Copilot, Recall y Click to Do desactivados.' ok
        Save-Journal
    }

    # ---- Rendimiento base
    Write-ZLog 'Rendimiento' head
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg $adv 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 1
    Set-ServiceStart 'RetailDemo' 'Disabled'
    Set-ServiceStart 'MapsBroker' 'Manual'
    Write-ZLog 'Menos animaciones, arranque sin retraso, Edge sin segundo plano, Sensor de almacenamiento.' ok

    if ($O.Aggressive) {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
        Set-Reg "$pol\AppPrivacy" 'LetAppsRunInBackground' 2
        if (-not $script:ZDryRun -and (Test-Path "$env:SystemDrive\hiberfil.sys")) {
            powercfg /hibernate off | Out-Null
            Add-JournalEntry @{ Kind = 'Hibernate' }
            Write-ZLog 'Hibernación desactivada.' ok
        }
        Write-ZLog 'Modo agresivo: sin transparencias ni apps en segundo plano.' ok
    }
    Save-Journal

    # ---- Gaming
    if ($gaming) {
        Write-ZLog 'Gaming' head
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' -1
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
        Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
        Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
        Write-ZLog 'Modo de juego, sin Game DVR, HAGS, sin Power Throttling, ratón 1:1, sin atajos de accesibilidad.' ok
        Save-Journal

        if ($laptop) {
            Write-ZLog 'Portátil: no se cambia el plan de energía (mejor para batería y temperaturas).' warn
        } elseif ($script:ZDryRun) {
            Write-ZLog 'Crear y activar Z. Plan' dry
        } else {
            $prev = Get-ActivePlanGuid
            if ($prev) { Add-JournalEntry @{ Kind = 'Power'; OldValue = $prev } }
            Install-ZPlan @{ Wifi = $true; NoSleep = $false; Activate = $true }
            Save-Journal
        }
    }

    # ---- Bloatware
    if ($O.RemoveBloat -or $O.DisableAI) {
        Write-ZLog 'Apps preinstaladas' head
        $bloat = @()
        if ($O.RemoveBloat) {
            $bloat += 'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch','Microsoft.GetHelp','Microsoft.Getstarted',
                      'Microsoft.MicrosoftSolitaireCollection','Microsoft.People','Microsoft.PowerAutomateDesktop','Microsoft.Todos',
                      'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.ZuneVideo','Microsoft.MicrosoftOfficeHub',
                      'Clipchamp.Clipchamp','MicrosoftCorporationII.QuickAssist','Microsoft.549981C3F5F10','Microsoft.Windows.DevHome',
                      'MSTeams','MicrosoftTeams'
            if ($O.Aggressive) { $bloat += 'Microsoft.OutlookForWindows' }
        }
        if ($O.DisableAI) { $bloat += 'Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider' }
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $removed = 0
        foreach ($name in $bloat) {
            $pkgs = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
            $prov = @($provisioned | Where-Object DisplayName -eq $name)
            if (-not $pkgs -and -not $prov) { continue }
            if ($script:ZDryRun) { Write-ZLog "Eliminar $name" dry; continue }
            foreach ($p in $pkgs) { try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop } catch {} }
            foreach ($p in $prov) { try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null } catch {} }
            Add-JournalEntry @{ Kind = 'Appx'; Name = $name }
            Write-ZLog "Eliminada: $name" ok
            $removed++
        }
        if (-not $removed -and -not $script:ZDryRun) { Write-ZLog 'No había nada que eliminar.' }
        Save-Journal
    }

    # ---- Limpieza
    if ($O.Cleanup) {
        Write-ZLog 'Limpieza' head
        if ($script:ZDryRun) {
            Write-ZLog 'Vaciar temporales, caché de Optimización de distribución, DISM y optimizar unidad' dry
        } else {
            foreach ($dir in @($env:TEMP, "$env:SystemRoot\Temp")) {
                Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-ZLog 'Temporales vaciados.' ok
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Write-ZLog 'Caché de Optimización de distribución vaciada.' ok } catch {}
            Write-ZLog 'Limpiando WinSxS con DISM (puede tardar varios minutos)…'
            $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart')
            if ($O.Aggressive) { $dismArgs += '/ResetBase' }
            & dism.exe @dismArgs | Out-Null
            Write-ZLog 'Almacén de componentes limpio.' ok
            try { Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop; Write-ZLog 'Unidad del sistema optimizada (TRIM).' ok } catch {}
            Write-ZLog ("Espacio liberado: {0} GB" -f [math]::Round((Get-FreeGB) - $freeBefore, 2)) ok
        }
    }

    Save-Journal
    if ($script:ZDryRun) {
        Write-ZLog 'Simulación terminada: no se ha cambiado nada.' ok
    } else {
        Write-ZLog "Optimización completada: $($script:Journal.Count) cambios registrados. Reinicia el equipo." ok
    }
    $script:ZDryRun = $false
}

# ===========================================================================
#  JUEGOS · FORTNITE
# ===========================================================================
$FGS = '/Script/FortniteGame.FortGameUserSettings'

$FortniteProfiles = [ordered]@{
    competitivo = [pscustomobject]@{ Name = 'Competitivo'
        Desc = 'Todo al mínimo, pantalla completa real y Reflex + Boost. El mínimo input lag posible.'
        Fullscreen = 0; View = 1; Tex = 0; Res = 100; Reflex = 2 }
    equilibrado = [pscustomobject]@{ Name = 'Máxima visibilidad'
        Desc = 'Como Competitivo, pero las construcciones lejanas aparecen antes y las texturas son altas. Necesita 6 GB de VRAM o más.'
        Fullscreen = 0; View = 3; Tex = 2; Res = 100; Reflex = 2 }
    sinbordes   = [pscustomobject]@{ Name = 'Sin bordes para streaming'
        Desc = 'Como Competitivo, pero en ventana sin bordes: Alt+Tab instantáneo y captura cómoda con OBS.'
        Fullscreen = 1; View = 1; Tex = 0; Res = 100; Reflex = 2 }
    modesto     = [pscustomobject]@{ Name = 'PC modesto'
        Desc = 'Para gráficas integradas o de gama baja: resolución 3D al 85 % y distancia mínima.'
        Fullscreen = 0; View = 0; Tex = 0; Res = 85; Reflex = 1 }
}

function Get-FortniteIniPath { Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini' }

function Get-FortniteExe {
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path $man) {
        foreach ($f in Get-ChildItem -LiteralPath $man -Filter '*.item' -ErrorAction SilentlyContinue) {
            try {
                $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                if ($j.AppName -eq 'Fortnite' -or $j.DisplayName -eq 'Fortnite') {
                    $exe = Join-Path $j.InstallLocation 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
                    if (Test-Path $exe) { return $exe }
                }
            } catch {}
        }
    }
    $fallback = Join-Path $env:ProgramFiles 'Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-IniValue([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return $null }
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match ('^\s*' + [regex]::Escape($Key) + '\s*=(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

function Set-IniValues([string]$Path, $Changes) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]][IO.File]::ReadAllLines($Path))
    $count = 0
    foreach ($section in $Changes.Keys) {
        $header = "[$section]"
        $h = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq $header) { $h = $i; break } }
        if ($h -lt 0) {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
            $lines.Add($header); $h = $lines.Count - 1
        }
        foreach ($key in $Changes[$section].Keys) {
            $val = [string]$Changes[$section][$key]
            $end = $lines.Count
            for ($i = $h + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimStart().StartsWith('[')) { $end = $i; break } }
            $found = $false
            for ($i = $h + 1; $i -lt $end; $i++) {
                if ($lines[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                    $new = "$key=$val"
                    if ($lines[$i] -ne $new) { $lines[$i] = $new; $count++ }
                    $found = $true; break
                }
            }
            if (-not $found) {
                $ins = $end
                while ($ins -gt $h + 1 -and $lines[$ins - 1].Trim() -eq '') { $ins-- }
                $lines.Insert($ins, "$key=$val"); $count++
            }
        }
    }
    [IO.File]::WriteAllLines($Path, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $count
}

function Get-FortniteChanges([string]$ProfileId, [double]$Fps, [int]$Reflex) {
    $p   = $FortniteProfiles[$ProfileId]
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $res = [string]::Format($inv, '{0:F6}', [double]$p.Res)
    $c = [ordered]@{}
    $c[$FGS] = [ordered]@{
        bMotionBlur                       = 'False'
        bShowGrass                        = 'False'
        bUseVSync                         = 'False'
        bUseNanite                        = 'False'
        bEnableDLSSFrameGeneration        = 'False'
        bUseDynamicResolution             = 'False'
        bUseGPUCrashDebugging             = 'False'
        FortAntiAliasingMethod            = 'Disabled'
        DesiredGlobalIlluminationQuality  = '0'
        DesiredReflectionQuality          = '0'
        PotentiallyUpscaledResolutionQuality = $res
        NeverUpscaledResolutionQuality    = $res
        bDisableMouseAcceleration         = 'True'
        LowInputLatencyModeIsEnabled      = 'True'
        LatencyTweak2                     = [string]$Reflex
        bAllowUIParallax                  = 'False'
        bStopRenderingInBackground        = 'True'
        FrameRateLimit                    = [string]::Format($inv, '{0:F6}', $Fps)
        FrontendFrameRateLimit            = '60.000000'
        PreferredFullscreenMode           = [string]$p.Fullscreen
        LastConfirmedFullscreenMode       = [string]$p.Fullscreen
    }
    $c['ScalabilityGroups'] = [ordered]@{
        'sg.ResolutionQuality'        = [string]$p.Res
        'sg.ViewDistanceQuality'      = [string]$p.View
        'sg.AntiAliasingQuality'      = '0'
        'sg.ShadowQuality'            = '0'
        'sg.GlobalIlluminationQuality'= '0'
        'sg.ReflectionQuality'        = '0'
        'sg.PostProcessQuality'       = '0'
        'sg.TextureQuality'           = [string]$p.Tex
        'sg.EffectsQuality'           = '0'
        'sg.FoliageQuality'           = '0'
        'sg.ShadingQuality'           = '0'
        'sg.LandscapeQuality'         = '0'
    }
    $c['PerformanceMode']  = [ordered]@{ MeshQuality = '0' }
    $c['D3DRHIPreference'] = [ordered]@{ PreferredRHI = 'dx11'; PreferredFeatureLevel = 'es31' }
    return $c
}

function Set-GpuPreference([string]$Exe) {
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -Path $k -Name $Exe -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
}

function Get-FortniteBackups {
    $d = Join-Path $ZRoot 'backups\fortnite'
    if (-not (Test-Path $d)) { return @() }
    Get-ChildItem -LiteralPath $d -Filter '*.ini' | Sort-Object Name -Descending
}

function Invoke-Fortnite([hashtable]$O) {
    $p = $FortniteProfiles[$O.Profile]
    Write-ZLog "Fortnite · $($p.Name)" head
    if (Get-Process -Name 'FortniteClient-Win64-Shipping' -ErrorAction SilentlyContinue) {
        Write-ZLog 'Fortnite está abierto. Ciérralo y vuelve a aplicar (el juego sobrescribe el archivo al salir).' err; return
    }
    $ini = Get-FortniteIniPath
    if (-not (Test-Path $ini)) {
        Write-ZLog 'No existe GameUserSettings.ini. Abre Fortnite una vez, pon el Modo de renderizado en Rendimiento, entra al lobby y ciérralo.' err; return
    }
    $bdir = Join-Path $ZRoot 'backups\fortnite'
    New-Item -ItemType Directory -Path $bdir -Force | Out-Null
    $bk = Join-Path $bdir ('GameUserSettings_{0}.ini' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $ini -Destination $bk -Force
    (Get-Item -LiteralPath $bk).IsReadOnly = $false
    Write-ZLog "Copia de seguridad: $(Split-Path $bk -Leaf)" ok

    $item = Get-Item -LiteralPath $ini
    if ($item.IsReadOnly) { $item.IsReadOnly = $false }

    $n = Set-IniValues $ini (Get-FortniteChanges $O.Profile $O.Fps $O.Reflex)
    $reflexTxt = @('Desactivado', 'Activado', 'Activado + Boost')[[int]$O.Reflex]
    $fpsTxt    = if ([double]$O.Fps -le 0) { 'sin límite' } else { "$([int]$O.Fps) FPS" }
    $fsTxt     = if ($p.Fullscreen -eq 0) { 'pantalla completa' } else { 'sin bordes' }
    Write-ZLog "$n valores cambiados · Rendimiento DX11 · $fsTxt · límite $fpsTxt · Reflex $reflexTxt" ok

    if ($O.ReadOnly) {
        (Get-Item -LiteralPath $ini).IsReadOnly = $true
        Write-ZLog 'Archivo en solo lectura: las actualizaciones no lo pisarán (los cambios hechos dentro del juego tampoco se guardarán).' ok
    }
    if ($O.GpuPref) {
        $exe = Get-FortniteExe
        if ($exe) { Set-GpuPreference $exe; Write-ZLog 'Windows usará la GPU de alto rendimiento para Fortnite.' ok }
        else { Write-ZLog 'No encontré el .exe de Fortnite para fijar la GPU de alto rendimiento.' warn }
    }
    Write-ZLog 'Listo. Abre Fortnite y comprueba que el Modo de renderizado indica Rendimiento.' ok
}

function Restore-Fortnite([string]$File) {
    if (Get-Process -Name 'FortniteClient-Win64-Shipping' -ErrorAction SilentlyContinue) { Write-ZLog 'Cierra Fortnite antes de restaurar.' err; return }
    if (-not (Test-Path $File)) { Write-ZLog 'No se encontró la copia.' err; return }
    $ini = Get-FortniteIniPath
    if (Test-Path $ini) { (Get-Item -LiteralPath $ini).IsReadOnly = $false }
    Copy-Item -LiteralPath $File -Destination $ini -Force
    (Get-Item -LiteralPath $ini).IsReadOnly = $false
    Write-ZLog "Configuración de Fortnite restaurada desde $(Split-Path $File -Leaf)" ok
}

# ===========================================================================
#  DESPACHADOR
# ===========================================================================
function Invoke-ZTask([string]$Task, [hashtable]$Opt) {
    try {
        switch ($Task) {
            'ZPlanInstall'    { Install-ZPlan $Opt }
            'ZPlanRemove'     { Remove-ZPlan }
            'PlanActivate'    { powercfg /setactive $Opt.Guid | Out-Null; Write-ZLog "Plan activado: $($Opt.Name)" ok }
            'PlanDefaults'    { powercfg -restoredefaultschemes | Out-Null; Write-ZLog 'Planes de energía de fábrica restaurados (Z. Plan eliminado).' ok }
            'Hibernate'       { if ($Opt.On) { powercfg /hibernate on } else { powercfg /hibernate off }; Write-ZLog ('Hibernación ' + $(if ($Opt.On) { 'activada' } else { 'desactivada' })) ok }
            'RegApply'        { Invoke-RegTweaks $Opt }
            'RegExport'       { Export-RegTweaks $Opt }
            'Optimize'        { Invoke-Optimizer $Opt }
            'OptRestore'      { Restore-Journal $Opt.Dir }
            'Fortnite'        { Invoke-Fortnite $Opt }
            'FortniteRestore' { Restore-Fortnite $Opt.File }
            'RestorePoint'    { Write-ZLog 'Punto de restauración' head; [void](New-ZRestorePoint 'Z. Optimizer: manual') }
            'Quick' {
                Invoke-Optimizer @{ Mode = 'Gaming'; RestorePoint = $true; Cleanup = $false }
                Invoke-RegTweaks @{ Action = 'Apply'; Ids = @($RegTweaks | Where-Object Rec | ForEach-Object Id) }
            }
        }
    } catch {
        Write-ZLog "Error: $($_.Exception.Message)" err
    }
}

}   # ---- fin del motor
$EngineText = $EngineCode.ToString()
. $EngineCode

# ===========================================================================
#  INTERFAZ
#  Paleta pizarra + ámbar de instrumento · Bahnschrift (títulos y datos) + Segoe UI Variable (texto)
# ===========================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Z. Optimizer" Width="1200" Height="820" MinWidth="1000" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#171B22" Foreground="#E6E9EE"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Display">Bahnschrift, Segoe UI</FontFamily>
    <FontFamily x:Key="Mono">Cascadia Mono, Consolas</FontFamily>
    <SolidColorBrush x:Key="Base"     Color="#171B22"/>
    <SolidColorBrush x:Key="Rail"     Color="#12161C"/>
    <SolidColorBrush x:Key="Surface"  Color="#1F242D"/>
    <SolidColorBrush x:Key="Raised"   Color="#262C37"/>
    <SolidColorBrush x:Key="Line"     Color="#2C3340"/>
    <SolidColorBrush x:Key="LineHi"   Color="#4A5466"/>
    <SolidColorBrush x:Key="Ink"      Color="#E6E9EE"/>
    <SolidColorBrush x:Key="Muted"    Color="#8D96A6"/>
    <SolidColorBrush x:Key="Faint"    Color="#5E6778"/>
    <SolidColorBrush x:Key="Amber"    Color="#F0A73A"/>
    <SolidColorBrush x:Key="AmberHi"  Color="#F6BC63"/>
    <SolidColorBrush x:Key="OnAmber"  Color="#1C1505"/>
    <SolidColorBrush x:Key="Ok"       Color="#5BC48D"/>
    <SolidColorBrush x:Key="Bad"      Color="#E86A6F"/>

    <!-- Texto -->
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="32"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontStretch" Value="SemiCondensed"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Lead" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="MaxWidth" Value="640"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="LineHeight" Value="22"/>
      <Setter Property="Margin" Value="0,0,0,28"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Note" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="20"/>
      <Setter Property="MaxWidth" Value="680"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="Key" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Val" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <!-- Estructura: secciones separadas por línea fina; panel solo para la acción principal -->
    <Style x:Key="Section" TargetType="Border">
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,1,0,0"/>
      <Setter Property="Padding" Value="0,22,0,26"/>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="24,22"/>
      <Setter Property="Margin" Value="0,0,0,28"/>
    </Style>

    <!-- Botones -->
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="{StaticResource Raised}"/>
      <Setter Property="BorderBrush" Value="#343C4A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{StaticResource LineHi}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Amber}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Amber}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Amber}"/>
      <Setter Property="Foreground" Value="{StaticResource OnAmber}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource AmberHi}"/>
          <Setter Property="BorderBrush" Value="{StaticResource AmberHi}"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Ink}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#5A3036"/>
      <Setter Property="Foreground" Value="{StaticResource Bad}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Bad}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Foreground" Value="{StaticResource Ink}"/>
          <Setter Property="BorderBrush" Value="Transparent"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Amber}"/></Trigger>
      </Style.Triggers>
    </Style>

    <!-- Casillas -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Margin" Value="0,6,0,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="box" Width="18" Height="18" CornerRadius="4" VerticalAlignment="Top" Margin="0,1,0,0"
                      Background="{StaticResource Surface}" BorderBrush="{StaticResource LineHi}" BorderThickness="1.5">
                <Path x:Name="tick" Data="M3.5,9 L7.5,13 L14.5,5" Stroke="{StaticResource OnAmber}" StrokeThickness="2.2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#6A7488"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Amber}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Amber}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Ink}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Opciones seleccionables (modo del optimizador, perfiles de Fortnite) -->
    <Style x:Key="Tile" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="18,16">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="16" Height="16" VerticalAlignment="Top" Margin="0,3,0,0">
                  <Ellipse x:Name="ring" Stroke="{StaticResource LineHi}" StrokeThickness="1.5"/>
                  <Ellipse x:Name="dot" Width="8" Height="8" Fill="{StaticResource Amber}" Visibility="Collapsed"/>
                </Grid>
                <ContentPresenter Grid.Column="1" Margin="12,0,0,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineHi}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Amber}"/>
                <Setter TargetName="b" Property="Background" Value="#262722"/>
                <Setter TargetName="ring" Property="Stroke" Value="{StaticResource Amber}"/>
                <Setter TargetName="dot" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderThickness" Value="2"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Carril de navegación: el marcador ámbar recorre una guía vertical -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Background="Transparent" Height="42">
              <Rectangle x:Name="mark" Width="3" HorizontalAlignment="Left" Margin="-1,8,0,8" Fill="{StaticResource Amber}" RadiusX="1.5" RadiusY="1.5" Opacity="0"/>
              <ContentPresenter Margin="22,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="{StaticResource Ink}"/>
                <Setter TargetName="mark" Property="Opacity" Value="1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Desplegables -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Padding="12,8" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#303745"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Amber}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="MinHeight" Value="38"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="tg" Focusable="False" ClickMode="Press" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" Background="#1F242D" BorderBrush="#343C4A" BorderThickness="1" CornerRadius="4">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0" Data="M0,0 L5,5 L10,0"
                            Stroke="#8D96A6" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#4A5466"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#F0A73A"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="cp" IsHitTestVisible="False" Margin="12,0,36,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Visibility="Hidden" Margin="8,0,34,0" VerticalAlignment="Center"
                       Background="Transparent" BorderThickness="0" Foreground="#E6E9EE" CaretBrush="#F0A73A"
                       FontSize="{TemplateBinding FontSize}" IsReadOnly="{TemplateBinding IsReadOnly}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="#262C37" BorderBrush="#343C4A" BorderThickness="1" CornerRadius="4" Margin="0,4,0,0" Padding="0,4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320">
                  <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="cp" Property="Visibility" Value="Hidden"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barras de desplazamiento finas -->
    <ControlTemplate x:Key="ThumbT" TargetType="Thumb">
      <Border CornerRadius="3" Background="#343C4A"/>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2,4">
              <Track.Thumb><Thumb Template="{StaticResource ThumbT}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="False" Margin="4,2">
                  <Track.Thumb><Thumb Template="{StaticResource ThumbT}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Page" TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Padding" Value="44,36,36,12"/>
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="232"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============ Carril ============ -->
    <Border Grid.Column="0" Background="{StaticResource Rail}" BorderBrush="#20252E" BorderThickness="0,0,1,0">
      <Grid Margin="28,30,20,24">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,40">
          <TextBlock Text="Z." FontFamily="{StaticResource Display}" FontSize="54" FontWeight="Bold" Foreground="{StaticResource Ink}" Margin="-2,0,0,-8"/>
          <TextBlock Text="Optimizer" FontFamily="{StaticResource Display}" FontSize="15" Foreground="{StaticResource Muted}"/>
        </StackPanel>
        <Border Grid.Row="1" BorderBrush="{StaticResource Line}" BorderThickness="1,0,0,0" VerticalAlignment="Top">
          <StackPanel>
            <RadioButton x:Name="NavHome"    Style="{StaticResource Nav}" GroupName="nav" Tag="PageHome"    IsChecked="True" Content="Inicio"/>
            <RadioButton x:Name="NavPlan"    Style="{StaticResource Nav}" GroupName="nav" Tag="PagePlan"    Content="Z. Plan"/>
            <RadioButton x:Name="NavReg"     Style="{StaticResource Nav}" GroupName="nav" Tag="PageReg"     Content="Registro"/>
            <RadioButton x:Name="NavOpt"     Style="{StaticResource Nav}" GroupName="nav" Tag="PageOpt"     Content="Optimizador"/>
            <RadioButton x:Name="NavGames"   Style="{StaticResource Nav}" GroupName="nav" Tag="PageGames"   Content="Juegos"/>
            <RadioButton x:Name="NavRestore" Style="{StaticResource Nav}" GroupName="nav" Tag="PageRestore" Content="Restaurar"/>
          </StackPanel>
        </Border>
        <StackPanel Grid.Row="2">
          <TextBlock Text="Plan de energía" FontSize="12" Foreground="{StaticResource Faint}"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,18">
            <Ellipse x:Name="RailDot" Width="7" Height="7" Fill="{StaticResource Faint}" VerticalAlignment="Center" Margin="0,1,8,0"/>
            <TextBlock x:Name="TxtRailPlan" FontFamily="{StaticResource Display}" FontSize="14" Text="—" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
          </StackPanel>
          <TextBlock x:Name="TxtVersion" FontSize="12" Foreground="{StaticResource Faint}" LineHeight="18"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ============ Contenido ============ -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="176"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">

        <!-- INICIO -->
        <ScrollViewer x:Name="PageHome" Style="{StaticResource Page}" Visibility="Visible">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock x:Name="TxtHello" Style="{StaticResource H1}" Text="Hola"/>
            <TextBlock x:Name="TxtHomeLead" Style="{StaticResource Lead}" Text=" "/>

            <Border Style="{StaticResource Panel}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource H2}" Text="Optimización recomendada para jugar"/>
                  <TextBlock Style="{StaticResource Note}" Text="Crea un punto de restauración, aplica el Optimizador en modo Gaming (con Z. Plan si es un sobremesa) y los ajustes de registro recomendados. No elimina apps ni toca la IA. Todo se deshace desde Restaurar."/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                  <Button x:Name="BtnQuick" Style="{StaticResource Primary}" Content="Optimizar para jugar" Margin="0,0,0,8" Padding="22,11"/>
                  <Button x:Name="BtnQuickRP" Style="{StaticResource Ghost}" Content="Solo crear punto de restauración" Margin="0"/>
                </StackPanel>
              </Grid>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Tu equipo" Margin="0,0,0,16"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Style="{StaticResource Key}" Text="Windows"/>
                  <TextBlock Grid.Row="0" Grid.Column="1" x:Name="SysOS" Style="{StaticResource Val}"/>
                  <TextBlock Grid.Row="1" Style="{StaticResource Key}" Text="Procesador"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" x:Name="SysCPU" Style="{StaticResource Val}"/>
                  <TextBlock Grid.Row="2" Style="{StaticResource Key}" Text="Gráfica"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" x:Name="SysGPU" Style="{StaticResource Val}"/>
                  <TextBlock Grid.Row="3" Style="{StaticResource Key}" Text="Memoria"/>
                  <TextBlock Grid.Row="3" Grid.Column="1" x:Name="SysRAM" Style="{StaticResource Val}"/>
                  <TextBlock Grid.Row="4" Style="{StaticResource Key}" Text="Monitor"/>
                  <TextBlock Grid.Row="4" Grid.Column="1" x:Name="SysHz" Style="{StaticResource Val}"/>
                  <TextBlock Grid.Row="5" Style="{StaticResource Key}" Text="Tipo de equipo"/>
                  <TextBlock Grid.Row="5" Grid.Column="1" x:Name="SysType" Style="{StaticResource Val}"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Qué reduce más el input lag"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,0,0,16" Text="Por orden de impacto. Esta app se ocupa del último punto; los anteriores se configuran en el juego y en el hardware."/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="36"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="1" FontFamily="{StaticResource Display}" FontSize="20" Foreground="{StaticResource Amber}"/>
                  <TextBlock Grid.Row="0" Grid.Column="1" Margin="0,3,0,12" Text="Reflex activado con Boost en cada juego, o Radeon Anti-Lag en AMD."/>
                  <TextBlock Grid.Row="1" Text="2" FontFamily="{StaticResource Display}" FontSize="20" Foreground="{StaticResource Amber}"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" Margin="0,3,0,12" Text="FPS estables. Sin Reflex, un límite unos FPS por debajo de los Hz del monitor."/>
                  <TextBlock Grid.Row="2" Text="3" FontFamily="{StaticResource Display}" FontSize="20" Foreground="{StaticResource Amber}"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" Margin="0,3,0,12" Text="Pantalla completa, muchos Hz y G-SYNC o FreeSync."/>
                  <TextBlock Grid.Row="3" Text="4" FontFamily="{StaticResource Display}" FontSize="20" Foreground="{StaticResource Amber}"/>
                  <TextBlock Grid.Row="3" Grid.Column="1" Margin="0,3,0,12" Text="Red por cable y ratón a 1000 o 2000 Hz."/>
                  <TextBlock Grid.Row="4" Text="5" FontFamily="{StaticResource Display}" FontSize="20" Foreground="{StaticResource Amber}"/>
                  <TextBlock Grid.Row="4" Grid.Column="1" Margin="0,3,0,0" Text="Windows sin ruido de fondo: plan de energía, procesos y ajustes de este programa."/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Z. PLAN -->
        <ScrollViewer x:Name="PagePlan" Style="{StaticResource Page}">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock Style="{StaticResource H1}" Text="Z. Plan"/>
            <TextBlock Style="{StaticResource Lead}" Text="Plan de energía propio basado en Máximo rendimiento. Reúne lo que funciona de Calypto y deja fuera lo que perjudica de Muren."/>

            <Border Style="{StaticResource Panel}">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                  <Ellipse x:Name="PlanDot" Width="10" Height="10" Fill="{StaticResource Faint}" VerticalAlignment="Center" Margin="0,2,10,0"/>
                  <TextBlock x:Name="TxtPlanStatus" FontFamily="{StaticResource Display}" FontSize="17" Text="—"/>
                </StackPanel>
                <CheckBox x:Name="ChkPlanWifi" IsChecked="True" Content="Adaptador Wi-Fi a máximo rendimiento"/>
                <CheckBox x:Name="ChkPlanSleep" Content="No suspender nunca automáticamente (solo sobremesa)"/>
                <CheckBox x:Name="ChkPlanHib" Content="Desactivar la hibernación. Libera varios GB y quita el inicio rápido"/>
                <WrapPanel Margin="0,18,0,0">
                  <Button x:Name="BtnPlanInstall" Style="{StaticResource Primary}" Content="Instalar y activar Z. Plan"/>
                  <Button x:Name="BtnPlanBalanced" Content="Volver a Equilibrado"/>
                  <Button x:Name="BtnPlanCpl" Style="{StaticResource Ghost}" Content="Opciones de energía de Windows"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Section}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="32"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Style="{StaticResource H2}" Text="Qué cambia" Margin="0,0,0,12"/>
                  <TextBlock Style="{StaticResource Note}" LineHeight="24" Text="CPU al 100 % de mínimo y máximo&#x0a;Sin aparcamiento de núcleos, también en los E-cores&#x0a;Turbo agresivo y preferencia por rendimiento&#x0a;PCI Express sin ahorro de energía (ASPM)&#x0a;USB sin suspensión selectiva&#x0a;El disco no se apaga"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Style="{StaticResource H2}" Text="Qué deja como está" Margin="0,0,0,12"/>
                  <TextBlock Style="{StaticResource Note}" LineHeight="24" Text="Los C-states: desactivarlos calienta la CPU y puede quitar turbo&#x0a;La contraseña al despertar y el botón de encendido&#x0a;Los valores con batería, en portátiles"/>
                </StackPanel>
              </Grid>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Planes instalados" Margin="0,0,0,14"/>
                <WrapPanel>
                  <ComboBox x:Name="CmbPlans" Width="360"/>
                  <Button x:Name="BtnPlanActivate" Content="Activar"/>
                  <Button x:Name="BtnPlanRefresh" Style="{StaticResource Ghost}" Content="Actualizar lista"/>
                  <Button x:Name="BtnPlanRemove" Style="{StaticResource Danger}" Content="Eliminar Z. Plan"/>
                </WrapPanel>
                <TextBlock Style="{StaticResource Note}" Margin="0,8,0,0" Text="Para comprobar si de verdad mejora, mide con LatencyMon antes y después. En CPUs modernas la frecuencia la gestiona el propio procesador, así que la diferencia suele ser pequeña."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- REGISTRO -->
        <ScrollViewer x:Name="PageReg" Style="{StaticResource Page}">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock Style="{StaticResource H1}" Text="Registro"/>
            <TextBlock Style="{StaticResource Lead}" Text="Ajustes comprobados en Windows 11 24H2, 25H2 y 26H2. Cada uno tiene su versión para revertir, y puedes exportarlos como archivos .reg."/>
            <WrapPanel Margin="0,0,0,14">
              <Button x:Name="BtnRegApply" Style="{StaticResource Primary}" Content="Aplicar marcados"/>
              <Button x:Name="BtnRegRevert" Content="Revertir marcados"/>
              <Button x:Name="BtnRegRec" Style="{StaticResource Ghost}" Content="Marcar recomendados"/>
              <Button x:Name="BtnRegNone" Style="{StaticResource Ghost}" Content="Desmarcar todo"/>
              <Button x:Name="BtnRegExport" Style="{StaticResource Ghost}" Content="Exportar .reg a Documentos"/>
            </WrapPanel>
            <StackPanel x:Name="RegList"/>
          </StackPanel>
        </ScrollViewer>

        <!-- OPTIMIZADOR -->
        <ScrollViewer x:Name="PageOpt" Style="{StaticResource Page}">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock Style="{StaticResource H1}" Text="Optimizador"/>
            <TextBlock Style="{StaticResource Lead}" Text="Telemetría al mínimo, sin anuncios ni Bing, menos procesos en segundo plano y limpieza. No toca Windows Update, Defender, SmartScreen ni el control de cuentas."/>
            <UniformGrid Columns="2" Margin="0,0,-12,14">
              <RadioButton x:Name="OptNormal" Style="{StaticResource Tile}" GroupName="mode" IsChecked="True">
                <StackPanel>
                  <TextBlock Text="Normal" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,4"/>
                  <TextBlock Style="{StaticResource Note}" Text="Privacidad, anuncios, interfaz y rendimiento base. No cambia el plan de energía."/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="OptGaming" Style="{StaticResource Tile}" GroupName="mode">
                <StackPanel>
                  <TextBlock Text="Gaming" FontFamily="{StaticResource Display}" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,4"/>
                  <TextBlock Style="{StaticResource Note}" Text="Lo de Normal y además Z. Plan, modo de juego, HAGS, ratón 1:1 y sin Game DVR, Power Throttling ni atajos de accesibilidad."/>
                </StackPanel>
              </RadioButton>
            </UniformGrid>
            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Opciones" Margin="0,0,0,10"/>
                <CheckBox x:Name="ChkOptRP" IsChecked="True" Content="Crear un punto de restauración antes"/>
                <CheckBox x:Name="ChkOptClean" IsChecked="True" Content="Limpiar temporales, WinSxS con DISM y hacer TRIM"/>
                <CheckBox x:Name="ChkOptBloat">
                  <StackPanel>
                    <TextBlock Text="Eliminar apps prescindibles"/>
                    <TextBlock Style="{StaticResource Note}" Text="Noticias, Tiempo, Solitaire, Clipchamp, Teams, Consejos y similares. Se conservan Store, Xbox, Fotos y Calculadora."/>
                  </StackPanel>
                </CheckBox>
                <CheckBox x:Name="ChkOptAI" Content="Desactivar Copilot, Recall y Click to Do, y desinstalar la app Copilot"/>
                <CheckBox x:Name="ChkOptAggr">
                  <StackPanel>
                    <TextBlock Text="Modo agresivo"/>
                    <TextBlock Style="{StaticResource Note}" Text="Sin transparencias, sin apps en segundo plano ni hibernación, DISM /ResetBase y sin el Outlook nuevo. Algunas apps avisarán con retraso."/>
                  </StackPanel>
                </CheckBox>
                <CheckBox x:Name="ChkOptDry" Content="Solo simular: muestra lo que haría sin cambiar nada"/>
                <WrapPanel Margin="0,20,0,0">
                  <Button x:Name="BtnOptRun" Style="{StaticResource Primary}" Content="Optimizar"/>
                  <Button x:Name="BtnOptUndo" Content="Deshacer la última optimización"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- JUEGOS -->
        <ScrollViewer x:Name="PageGames" Style="{StaticResource Page}">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock Style="{StaticResource H1}" Text="Fortnite"/>
            <TextBlock Style="{StaticResource Lead}" Text="Modo Rendimiento sobre DX11. Solo se cambian los valores necesarios de tu GameUserSettings.ini: sensibilidad, controles, audio y cuenta se conservan."/>

            <Border Style="{StaticResource Panel}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="170"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Style="{StaticResource Key}" Text="Configuración"/>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="FnCfg" Style="{StaticResource Val}"/>
                <Button Grid.Row="0" Grid.Column="2" x:Name="BtnFnRefresh" Style="{StaticResource Ghost}" Content="Actualizar" Margin="0" VerticalAlignment="Top"/>
                <TextBlock Grid.Row="1" Style="{StaticResource Key}" Text="Modo de renderizado"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="FnMode" Style="{StaticResource Val}"/>
                <TextBlock Grid.Row="2" Style="{StaticResource Key}" Text="Límite de FPS"/>
                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="FnFps" Style="{StaticResource Val}"/>
                <TextBlock Grid.Row="3" Style="{StaticResource Key}" Text="NVIDIA Reflex"/>
                <TextBlock Grid.Row="3" Grid.Column="1" x:Name="FnReflex" Style="{StaticResource Val}"/>
                <TextBlock Grid.Row="4" Style="{StaticResource Key}" Text="Ventana"/>
                <TextBlock Grid.Row="4" Grid.Column="1" x:Name="FnWindow" Style="{StaticResource Val}"/>
                <TextBlock Grid.Row="5" Style="{StaticResource Key}" Text="Juego instalado en"/>
                <TextBlock Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" x:Name="FnExe" Style="{StaticResource Val}" FontSize="13"/>
              </Grid>
            </Border>
            <Border x:Name="FnWarnBox" Background="#2E2418" BorderBrush="#6B4E22" BorderThickness="1" CornerRadius="6" Padding="16,12" Margin="0,-14,0,28" Visibility="Collapsed">
              <TextBlock x:Name="FnWarn" Foreground="{StaticResource AmberHi}"/>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Perfil" Margin="0,0,0,14"/>
                <UniformGrid x:Name="FnProfiles" Columns="2" Margin="0,0,-12,10"/>
                <Grid Margin="0,6,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="24"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Límite de FPS" Margin="0,0,0,8"/>
                    <ComboBox x:Name="CmbFnFps" IsEditable="True" Margin="0,0,0,6"/>
                    <TextBlock x:Name="TxtFnHz" Style="{StaticResource Note}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="NVIDIA Reflex" Margin="0,0,0,8"/>
                    <ComboBox x:Name="CmbFnReflex" Margin="0,0,0,6"/>
                    <TextBlock Style="{StaticResource Note}" Text="En gráficas AMD no tiene efecto: activa Radeon Anti-Lag en Adrenalin."/>
                  </StackPanel>
                </Grid>
                <CheckBox x:Name="ChkFnGpu" IsChecked="True" Content="Usar siempre la gráfica de alto rendimiento para Fortnite"/>
                <CheckBox x:Name="ChkFnRO">
                  <StackPanel>
                    <TextBlock Text="Bloquear el archivo (solo lectura)"/>
                    <TextBlock Style="{StaticResource Note}" Text="Las actualizaciones no lo cambiarán, pero tampoco se guardará lo que ajustes dentro del juego."/>
                  </StackPanel>
                </CheckBox>
                <WrapPanel Margin="0,20,0,0">
                  <Button x:Name="BtnFnApply" Style="{StaticResource Primary}" Content="Aplicar a Fortnite"/>
                  <Button x:Name="BtnFnOpen" Style="{StaticResource Ghost}" Content="Abrir la carpeta de configuración"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Copias de seguridad"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,0,0,14" Text="Se guarda una copia cada vez que aplicas un perfil."/>
                <WrapPanel>
                  <ComboBox x:Name="CmbFnBackups" Width="380"/>
                  <Button x:Name="BtnFnRestore" Content="Restaurar esta copia"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Ajustes que solo se cambian dentro del juego"/>
                <TextBlock Style="{StaticResource Note}" LineHeight="24" Margin="0,6,0,0" Text="Confirmar edición al soltar: activado. Restablecer elección de construcción: desactivado.&#x0a;Activa el ping y la pérdida de paquetes en las estadísticas de red: si una edición falla justo en un pico, el problema es la conexión.&#x0a;Tras cambiar el driver o la configuración, las primeras partidas tienen tirones mientras se compilan los shaders."/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Otros juegos"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,0,0,14" Text="Indica a Windows que use siempre la gráfica de alto rendimiento con cualquier juego, igual que en Configuración, Pantalla, Gráficos."/>
                <Button x:Name="BtnGpuExe" HorizontalAlignment="Left" Content="Elegir el .exe de un juego"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- RESTAURAR -->
        <ScrollViewer x:Name="PageRestore" Style="{StaticResource Page}">
          <StackPanel MaxWidth="880" HorizontalAlignment="Left">
            <TextBlock Style="{StaticResource H1}" Text="Restaurar"/>
            <TextBlock Style="{StaticResource Lead}" Text="Todo lo que hace Z. Optimizer se puede deshacer desde aquí."/>
            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Optimizaciones"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,0,0,14" Text="Cada vez que ejecutas el optimizador se guarda el valor original de cada cambio."/>
                <WrapPanel>
                  <ComboBox x:Name="CmbJournals" Width="400"/>
                  <Button x:Name="BtnJournalRestore" Content="Deshacer esta optimización"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Ajustes de registro"/>
                <TextBlock x:Name="TxtRegApplied" Style="{StaticResource Note}" Margin="0,0,0,14"/>
                <Button x:Name="BtnRegRevertAll" HorizontalAlignment="Left" Content="Revertir todos los ajustes de registro"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Section}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Sistema" Margin="0,0,0,14"/>
                <WrapPanel>
                  <Button x:Name="BtnRP" Content="Crear punto de restauración"/>
                  <Button x:Name="BtnRstrui" Content="Abrir Restaurar sistema"/>
                  <Button x:Name="BtnHibOn" Content="Reactivar la hibernación"/>
                  <Button x:Name="BtnOpenData" Style="{StaticResource Ghost}" Content="Abrir la carpeta de datos"/>
                </WrapPanel>
                <Button x:Name="BtnPlanDefaults" Style="{StaticResource Danger}" HorizontalAlignment="Left" Margin="0,10,0,0" Content="Restaurar los planes de energía de fábrica"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- ============ Consola de actividad ============ -->
      <Border Grid.Row="1" Background="{StaticResource Rail}" BorderBrush="#20252E" BorderThickness="0,1,0,0">
        <Grid Margin="44,10,24,12">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Actividad" FontFamily="{StaticResource Display}" FontSize="14" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="TxtBusy" Text="Trabajando…" FontSize="13" Foreground="{StaticResource Amber}" Margin="14,0,12,0" VerticalAlignment="Center" Visibility="Hidden"/>
            <Button Grid.Column="2" x:Name="BtnClearLog" Style="{StaticResource Ghost}" Content="Limpiar" Margin="0"/>
          </Grid>
          <ProgressBar Grid.Row="0" x:Name="Busy" Height="2" VerticalAlignment="Bottom" Margin="0,0,0,-4" Visibility="Hidden"
                       Foreground="{StaticResource Amber}" Background="Transparent" BorderThickness="0"/>
          <TextBox Grid.Row="1" x:Name="LogBox" IsReadOnly="True" Background="Transparent" Foreground="#B7BECB" BorderThickness="0"
                   FontFamily="{StaticResource Mono}" FontSize="12.5" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"
                   Margin="0,8,0,0" Padding="0" SelectionBrush="#F0A73A"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $n = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -First 1 -ExpandProperty Value
    $ui[$n] = $window.FindName($n)
}

# Barra de título oscura en Windows 11
try {
    Add-Type -Namespace ZOpt -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);' -ErrorAction Stop
    $window.Add_SourceInitialized({
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $on = 1;          [void][ZOpt.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)   # modo oscuro
        $cap = 0x001C1612; [void][ZOpt.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$cap, 4) # color del título (BGR) = #12161C
    })
} catch {}

$Pages = 'PageHome', 'PagePlan', 'PageReg', 'PageOpt', 'PageGames', 'PageRestore'
$script:RegChecks   = @{}
$script:FnRadios    = @{}
$script:AfterAction = $null
$script:MonitorHz   = $null

function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
function New-Thick([double]$l, [double]$t, [double]$r, [double]$b) { New-Object System.Windows.Thickness($l, $t, $r, $b) }
function Get-Res([string]$Key) { $window.FindResource($Key) }
function Confirm-Z([string]$Text) {
    [System.Windows.MessageBox]::Show($Text, 'Z. Optimizer', 'YesNo', 'Question') -eq 'Yes'
}
function Show-Info([string]$Text) {
    [System.Windows.MessageBox]::Show($Text, 'Z. Optimizer', 'OK', 'Information') | Out-Null
}
function New-Tag([string]$Text, [string]$Hex) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = 12; $t.Foreground = New-Brush $Hex
    $t.Margin = New-Thick 10 2 0 0; $t.VerticalAlignment = 'Center'
    $t
}

# ---------------------------------------------------------------- tareas en segundo plano
function Start-ZTask([string]$Task, [hashtable]$Opt = @{}, [scriptblock]$After = $null) {
    if ($sync.Busy) { Show-Info 'Hay una tarea en curso. Espera a que termine.'; return }
    $sync.Busy = $true
    $script:AfterAction = $After
    $ui.Busy.Visibility = 'Visible'; $ui.Busy.IsIndeterminate = $true; $ui.TxtBusy.Visibility = 'Visible'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('ZTask', $Task)
    $rs.SessionStateProxy.SetVariable('ZOpt', $Opt)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($EngineText + "`nInvoke-ZTask -Task `$ZTask -Opt `$ZOpt")
    $sync.PS = $ps; $sync.RS = $rs
    $sync.Handle = $ps.BeginInvoke()
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $ui.LogBox.AppendText($sb.ToString()); $ui.LogBox.ScrollToEnd() }

    if ($sync.Busy -and $sync.Handle -and $sync.Handle.IsCompleted) {
        try { [void]$sync.PS.EndInvoke($sync.Handle) } catch { Write-ZLog $_.Exception.Message err }
        $errs = @($sync.PS.Streams.Error)
        if ($errs.Count -gt 0) { Write-ZLog "Avisos internos de PowerShell: $($errs.Count), normalmente inofensivos." info }
        $sync.PS.Dispose(); $sync.RS.Close(); $sync.RS.Dispose()
        $sync.Busy = $false; $sync.Handle = $null
        $ui.Busy.IsIndeterminate = $false; $ui.Busy.Visibility = 'Hidden'; $ui.TxtBusy.Visibility = 'Hidden'
        if ($script:AfterAction) {
            $a = $script:AfterAction; $script:AfterAction = $null
            try { & $a } catch {}
        }
    }
})

# ---------------------------------------------------------------- refrescos
function Update-Rail {
    $plan = Get-PowerPlans | Where-Object Active | Select-Object -First 1
    $ui.TxtRailPlan.Text = if ($plan) { $plan.Name } else { 'Desconocido' }
    $ui.RailDot.Fill = if ($plan -and $plan.Name -eq $ZPlanName) { Get-Res 'Amber' } else { Get-Res 'Faint' }
    return $plan
}

function Update-SysInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() -replace '\s+', ' '
    $gpu = (@(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Meta|Parsec|Remote|Mirror' } | ForEach-Object Name) -join "`n")
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $hz  = (@(Get-CimInstance Win32_VideoController | ForEach-Object CurrentRefreshRate | Where-Object { $_ -gt 1 }) | Measure-Object -Maximum).Maximum
    $laptop = Test-IsLaptop
    $script:MonitorHz = $hz

    $ui.TxtHello.Text = "Hola, $env:USERNAME"
    $ui.SysOS.Text   = "$($os.Caption -replace '^Microsoft ', ''), versión $($cv.DisplayVersion) (compilación $($cv.CurrentBuild).$($cv.UBR))"
    $ui.SysCPU.Text  = $cpu
    $ui.SysGPU.Text  = $gpu
    $ui.SysRAM.Text  = "$ram GB"
    $ui.SysHz.Text   = if ($hz) { "$hz Hz" } else { 'No detectado' }
    $ui.SysType.Text = if ($laptop) { 'Portátil' } else { 'Sobremesa' }

    $plan = Update-Rail
    $nReg = @(Get-RegApplied).Count
    $planTxt = if ($plan -and $plan.Name -eq $ZPlanName) { 'Z. Plan está activo' } elseif ($plan) { "El plan activo es $($plan.Name)" } else { 'No se pudo leer el plan de energía' }
    $regTxt  = switch ($nReg) { 0 { 'todavía no hay ajustes de registro aplicados' } 1 { 'hay 1 ajuste de registro aplicado' } default { "hay $nReg ajustes de registro aplicados" } }
    $ui.TxtHomeLead.Text = "$planTxt y $regTxt."
    if ([int]$cv.CurrentBuild -lt 22000) { Write-ZLog 'Este equipo no tiene Windows 11: muchas opciones no se aplicarán.' warn }
}

function Update-Plans {
    $plans = @(Get-PowerPlans)
    $ui.CmbPlans.Items.Clear()
    foreach ($p in $plans) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = $p.Name + $(if ($p.Active) { '  (activo)' } else { '' })
        $it.Tag = $p
        [void]$ui.CmbPlans.Items.Add($it)
        if ($p.Active) { $ui.CmbPlans.SelectedItem = $it }
    }
    $active = $plans | Where-Object Active | Select-Object -First 1
    $z = $plans | Where-Object Name -eq $ZPlanName
    if ($z -and $active.Name -eq $ZPlanName) {
        $ui.TxtPlanStatus.Text = 'Z. Plan está instalado y activo'; $ui.PlanDot.Fill = Get-Res 'Ok'
        $ui.BtnPlanInstall.Content = 'Reinstalar Z. Plan con estas opciones'
    } elseif ($z) {
        $ui.TxtPlanStatus.Text = "Z. Plan está instalado, pero el plan activo es $($active.Name)"; $ui.PlanDot.Fill = Get-Res 'Amber'
        $ui.BtnPlanInstall.Content = 'Reinstalar y activar Z. Plan'
    } else {
        $ui.TxtPlanStatus.Text = "Z. Plan no está instalado. Plan activo: $($active.Name)"; $ui.PlanDot.Fill = Get-Res 'Faint'
        $ui.BtnPlanInstall.Content = 'Instalar y activar Z. Plan'
    }
    [void](Update-Rail)
}

function Update-RegList {
    $applied = Get-RegApplied
    $prev = @{}
    foreach ($k in $script:RegChecks.Keys) { $prev[$k] = $script:RegChecks[$k].IsChecked }
    $ui.RegList.Children.Clear(); $script:RegChecks = @{}
    foreach ($cat in ($RegTweaks | ForEach-Object Cat | Select-Object -Unique)) {
        $sec = New-Object System.Windows.Controls.Border
        $sec.Style = Get-Res 'Section'
        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $cat; $h.Style = Get-Res 'H2'; $h.Margin = New-Thick 0 0 0 10
        [void]$sp.Children.Add($h)
        foreach ($t in ($RegTweaks | Where-Object Cat -eq $cat)) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Tag = $t.Id; $cb.Margin = New-Thick 0 8 0 8
            $body = New-Object System.Windows.Controls.StackPanel
            $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
            $n = New-Object System.Windows.Controls.TextBlock; $n.Text = $t.Name
            [void]$row.Children.Add($n)
            if ($applied -contains $t.Id) { [void]$row.Children.Add((New-Tag '● Aplicado' '#5BC48D')) }
            elseif ($t.Rec)               { [void]$row.Children.Add((New-Tag 'Recomendado' '#F0A73A')) }
            $d = New-Object System.Windows.Controls.TextBlock
            $d.Text = $t.Desc; $d.Style = Get-Res 'Note'; $d.Margin = New-Thick 0 2 0 0
            [void]$body.Children.Add($row); [void]$body.Children.Add($d)
            $cb.Content = $body
            if ($prev.ContainsKey($t.Id)) { $cb.IsChecked = $prev[$t.Id] }
            $script:RegChecks[$t.Id] = $cb
            [void]$sp.Children.Add($cb)
        }
        $sec.Child = $sp
        [void]$ui.RegList.Children.Add($sec)
    }
    $names = @($RegTweaks | Where-Object { $applied -contains $_.Id } | ForEach-Object Name)
    $ui.TxtRegApplied.Text = if ($names) { "Aplicados con Z. Optimizer: $($names -join ', ')." } else { 'No hay ningún ajuste de registro aplicado con Z. Optimizer.' }
}

function Get-SelectedRegIds { @($RegTweaks | Where-Object { $script:RegChecks[$_.Id].IsChecked } | ForEach-Object Id) }

function Update-Journals {
    $ui.CmbJournals.Items.Clear()
    foreach ($j in (Get-Journals)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $label = $j.Name
        if ($j.Name -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(.+)$') {
            $mode = $Matches[7]; $done = $mode -like '*-restaurado'; $mode = $mode -replace '-restaurado', ''
            $label = 'Modo {5}, {2}/{1}/{0} a las {3}:{4}{6}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $mode, $(if ($done) { ' (ya deshecha)' } else { '' })
        }
        $it.Content = $label; $it.Tag = $j.FullName
        [void]$ui.CmbJournals.Items.Add($it)
    }
    if ($ui.CmbJournals.Items.Count) { $ui.CmbJournals.SelectedIndex = 0; $ui.BtnJournalRestore.IsEnabled = $true }
    else { $ui.BtnJournalRestore.IsEnabled = $false }
}

function Update-Fortnite {
    $ini = Get-FortniteIniPath
    $exe = Get-FortniteExe
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if (Test-Path $ini) {
        $fl  = Get-IniValue $ini 'PreferredFeatureLevel'
        $fps = Get-IniValue $ini 'FrameRateLimit'
        $rfx = Get-IniValue $ini 'LatencyTweak2'
        $fs  = Get-IniValue $ini 'PreferredFullscreenMode'
        $ro  = (Get-Item -LiteralPath $ini).IsReadOnly
        $ui.FnCfg.Text    = if ($ro) { 'Encontrada, bloqueada en solo lectura' } else { 'Encontrada' }
        $ui.FnMode.Text   = if ($fl -eq 'es31') { 'Rendimiento (DX11)' } else { "Otro ($fl). Se cambiará a Rendimiento" }
        $fpsVal = 0.0; [void][double]::TryParse([string]$fps, [Globalization.NumberStyles]::Float, $inv, [ref]$fpsVal)
        $ui.FnFps.Text    = if ($fpsVal -gt 0) { "$([int]$fpsVal) FPS" } else { 'Sin límite' }
        $ui.FnReflex.Text = switch ($rfx) { '0' { 'Desactivado' } '1' { 'Activado' } '2' { 'Activado con Boost' } default { 'Sin definir' } }
        $ui.FnWindow.Text = switch ($fs) { '0' { 'Pantalla completa' } '1' { 'Ventana sin bordes' } '2' { 'Ventana' } default { 'Sin definir' } }
    } else {
        $ui.FnCfg.Text = 'No encontrada. Abre Fortnite una vez, entra al lobby y ciérralo'
        foreach ($k in 'FnMode', 'FnFps', 'FnReflex', 'FnWindow') { $ui[$k].Text = '—' }
    }
    $ui.FnExe.Text = if ($exe) { Split-Path (Split-Path (Split-Path (Split-Path $exe))) } else { 'No localizado. Solo hace falta para fijar la gráfica de alto rendimiento' }

    if (Get-Process -Name 'FortniteClient-Win64-Shipping' -ErrorAction SilentlyContinue) {
        $ui.FnWarn.Text = 'Fortnite está abierto. Ciérralo antes de aplicar un perfil: el juego reescribe el archivo al salir.'
        $ui.FnWarnBox.Visibility = 'Visible'
    } else { $ui.FnWarnBox.Visibility = 'Collapsed' }

    $ui.CmbFnBackups.Items.Clear()
    foreach ($b in (Get-FortniteBackups)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $label = $b.Name
        if ($b.Name -match '_(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.ini$') {
            $label = 'Copia del {2}/{1}/{0} a las {3}:{4}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5]
        }
        $it.Content = $label; $it.Tag = $b.FullName
        [void]$ui.CmbFnBackups.Items.Add($it)
    }
    if ($ui.CmbFnBackups.Items.Count) { $ui.CmbFnBackups.SelectedIndex = 0; $ui.BtnFnRestore.IsEnabled = $true }
    else { $ui.BtnFnRestore.IsEnabled = $false }
}

function Show-Page([string]$Name) {
    foreach ($p in $Pages) { $ui[$p].Visibility = $(if ($p -eq $Name) { 'Visible' } else { 'Collapsed' }) }
    $ui[$Name].ScrollToTop()
    switch ($Name) {
        'PageHome'    { Update-SysInfo }
        'PagePlan'    { Update-Plans }
        'PageGames'   { Update-Fortnite }
        'PageRestore' { Update-Journals; Update-RegList }
        'PageReg'     { Update-RegList }
    }
}

# ---------------------------------------------------------------- construcción dinámica
$first = $true
foreach ($id in $FortniteProfiles.Keys) {
    $p  = $FortniteProfiles[$id]
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = Get-Res 'Tile'; $rb.GroupName = 'fnprofile'; $rb.Tag = $id
    $sp = New-Object System.Windows.Controls.StackPanel
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $p.Name; $a.FontFamily = Get-Res 'Display'; $a.FontSize = 16; $a.FontWeight = [System.Windows.FontWeights]::SemiBold; $a.Margin = New-Thick 0 0 0 4
    $b = New-Object System.Windows.Controls.TextBlock; $b.Text = $p.Desc; $b.Style = Get-Res 'Note'
    [void]$sp.Children.Add($a); [void]$sp.Children.Add($b)
    $rb.Content = $sp
    $rb.Add_Checked({ param($s, $e) $ui.CmbFnReflex.SelectedIndex = [int]$FortniteProfiles[[string]$s.Tag].Reflex })
    $script:FnRadios[$id] = $rb
    [void]$ui.FnProfiles.Children.Add($rb)
    if ($first) { $rb.IsChecked = $true; $first = $false }
}

foreach ($r in 'Desactivado', 'Activado', 'Activado con Boost') { [void]$ui.CmbFnReflex.Items.Add($r) }
$ui.CmbFnReflex.SelectedIndex = 2
foreach ($f in 'Sin límite', '60', '120', '144', '165', '180', '237', '270', '300', '357', '480') { [void]$ui.CmbFnFps.Items.Add($f) }
$ui.CmbFnFps.SelectedIndex = 0

# ---------------------------------------------------------------- eventos
$navHandler = { param($s, $e) Show-Page ([string]$s.Tag) }
foreach ($n in 'NavHome', 'NavPlan', 'NavReg', 'NavOpt', 'NavGames', 'NavRestore') { $ui[$n].Add_Checked($navHandler) }

$ui.BtnClearLog.Add_Click({ $ui.LogBox.Clear() })

# Inicio
$ui.BtnQuick.Add_Click({
    if (Confirm-Z "Se creará un punto de restauración y después se aplicarán:`n`n- El Optimizador en modo Gaming, con Z. Plan si es un sobremesa`n- Los ajustes de registro recomendados`n`nTodo se puede deshacer desde Restaurar. ¿Continuar?") {
        Start-ZTask 'Quick' @{} { Update-SysInfo; Update-RegList }
    }
})
$ui.BtnQuickRP.Add_Click({ Start-ZTask 'RestorePoint' })

# Z. Plan
$ui.BtnPlanInstall.Add_Click({
    $o = @{ Wifi = [bool]$ui.ChkPlanWifi.IsChecked; NoSleep = [bool]$ui.ChkPlanSleep.IsChecked; Hibernate = [bool]$ui.ChkPlanHib.IsChecked; Activate = $true }
    Start-ZTask 'ZPlanInstall' $o { Update-Plans }
})
$ui.BtnPlanBalanced.Add_Click({ Start-ZTask 'PlanActivate' @{ Guid = $Guid_Balanced; Name = 'Equilibrado' } { Update-Plans } })
$ui.BtnPlanRemove.Add_Click({ if (Confirm-Z '¿Eliminar Z. Plan? Si está activo, se activará Equilibrado.') { Start-ZTask 'ZPlanRemove' @{} { Update-Plans } } })
$ui.BtnPlanCpl.Add_Click({ Start-Process control.exe 'powercfg.cpl' })
$ui.BtnPlanRefresh.Add_Click({ Update-Plans })
$ui.BtnPlanActivate.Add_Click({
    $it = $ui.CmbPlans.SelectedItem
    if ($it) { Start-ZTask 'PlanActivate' @{ Guid = $it.Tag.Guid; Name = $it.Tag.Name } { Update-Plans } }
})

# Registro
$ui.BtnRegRec.Add_Click({ foreach ($t in $RegTweaks) { $script:RegChecks[$t.Id].IsChecked = [bool]$t.Rec } })
$ui.BtnRegNone.Add_Click({ foreach ($k in $script:RegChecks.Keys) { $script:RegChecks[$k].IsChecked = $false } })
$ui.BtnRegApply.Add_Click({
    $ids = Get-SelectedRegIds
    if (-not $ids) { Show-Info 'Marca al menos un ajuste para aplicarlo.'; return }
    Start-ZTask 'RegApply' @{ Action = 'Apply'; Ids = $ids } { Update-RegList }
})
$ui.BtnRegRevert.Add_Click({
    $ids = Get-SelectedRegIds
    if (-not $ids) { Show-Info 'Marca al menos un ajuste para revertirlo.'; return }
    Start-ZTask 'RegApply' @{ Action = 'Revert'; Ids = $ids } { Update-RegList }
})
$ui.BtnRegExport.Add_Click({ Start-ZTask 'RegExport' @{ Ids = (Get-SelectedRegIds) } })

# Optimizador
$ui.BtnOptRun.Add_Click({
    $o = @{
        Mode         = $(if ($ui.OptGaming.IsChecked) { 'Gaming' } else { 'Normal' })
        RestorePoint = [bool]$ui.ChkOptRP.IsChecked
        Cleanup      = [bool]$ui.ChkOptClean.IsChecked
        RemoveBloat  = [bool]$ui.ChkOptBloat.IsChecked
        DisableAI    = [bool]$ui.ChkOptAI.IsChecked
        Aggressive   = [bool]$ui.ChkOptAggr.IsChecked
        DryRun       = [bool]$ui.ChkOptDry.IsChecked
    }
    if (-not $o.DryRun -and -not (Confirm-Z "Se aplicará el modo $($o.Mode). Cada cambio queda registrado para poder deshacerlo.`n¿Continuar?")) { return }
    Start-ZTask 'Optimize' $o { Update-SysInfo }
})
$ui.BtnOptUndo.Add_Click({
    $j = Get-Journals | Where-Object Name -notlike '*-restaurado' | Select-Object -First 1
    if (-not $j) { Show-Info 'No hay ninguna optimización pendiente de deshacer.'; return }
    if (Confirm-Z '¿Deshacer la última optimización?') { Start-ZTask 'OptRestore' @{ Dir = $j.FullName } { Update-SysInfo; Update-Journals } }
})

# Juegos
$ui.BtnFnRefresh.Add_Click({ Update-Fortnite })
$ui.BtnFnOpen.Add_Click({
    $d = Split-Path (Get-FortniteIniPath)
    if (Test-Path $d) { Start-Process explorer.exe $d } else { Show-Info 'La carpeta todavía no existe. Abre Fortnite una vez y ciérralo.' }
})
$ui.BtnFnApply.Add_Click({
    $prof = ($script:FnRadios.GetEnumerator() | Where-Object { $_.Value.IsChecked } | Select-Object -First 1).Key
    $fps  = 0
    if ([string]$ui.CmbFnFps.Text -match '^\s*(\d+)') { $fps = [double]$Matches[1] }
    Start-ZTask 'Fortnite' @{
        Profile  = $prof
        Fps      = $fps
        Reflex   = [int]$ui.CmbFnReflex.SelectedIndex
        ReadOnly = [bool]$ui.ChkFnRO.IsChecked
        GpuPref  = [bool]$ui.ChkFnGpu.IsChecked
    } { Update-Fortnite }
})
$ui.BtnFnRestore.Add_Click({
    $it = $ui.CmbFnBackups.SelectedItem
    if (-not $it) { return }
    if (Confirm-Z "¿Restaurar la $($it.Content.ToString().ToLower())?") { Start-ZTask 'FortniteRestore' @{ File = $it.Tag } { Update-Fortnite } }
})
$ui.BtnGpuExe.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Ejecutables (*.exe)|*.exe'
    $dlg.Title  = 'Elige el .exe del juego'
    if ($dlg.ShowDialog($window)) {
        try { Set-GpuPreference $dlg.FileName; Write-ZLog "Gráfica de alto rendimiento fijada para $([IO.Path]::GetFileName($dlg.FileName))" ok }
        catch { Write-ZLog "No se pudo fijar la gráfica: $($_.Exception.Message)" err }
    }
})

# Restaurar
$ui.BtnJournalRestore.Add_Click({
    $it = $ui.CmbJournals.SelectedItem
    if (-not $it) { return }
    if (Confirm-Z "¿Deshacer la optimización en $($it.Content)?") { Start-ZTask 'OptRestore' @{ Dir = $it.Tag } { Update-Journals; Update-SysInfo } }
})
$ui.BtnRegRevertAll.Add_Click({
    $ids = @(Get-RegApplied)
    if (-not $ids) { Show-Info 'No hay ajustes de registro aplicados.'; return }
    if (Confirm-Z "¿Revertir los $($ids.Count) ajustes de registro aplicados?") { Start-ZTask 'RegApply' @{ Action = 'Revert'; Ids = $ids } { Update-RegList } }
})
$ui.BtnRP.Add_Click({ Start-ZTask 'RestorePoint' })
$ui.BtnRstrui.Add_Click({ Start-Process rstrui.exe })
$ui.BtnHibOn.Add_Click({ Start-ZTask 'Hibernate' @{ On = $true } })
$ui.BtnOpenData.Add_Click({ Start-Process explorer.exe $ZRoot })
$ui.BtnPlanDefaults.Add_Click({
    if (Confirm-Z 'Se restaurarán los planes de energía de fábrica y se eliminarán todos los planes personalizados, incluido Z. Plan. ¿Continuar?') {
        Start-ZTask 'PlanDefaults' @{} { Update-Plans }
    }
})

$window.Add_Closing({
    param($s, $e)
    if ($sync.Busy -and -not (Confirm-Z 'Hay una tarea en curso y podría quedar a medias. ¿Cerrar igualmente?')) { $e.Cancel = $true }
})

# ---------------------------------------------------------------- arranque
$ui.TxtVersion.Text = "Versión 1.1`nWindows 11 24H2 a 26H2"
Update-SysInfo
Update-RegList
$ui.TxtFnHz.Text = if ($script:MonitorHz) {
    "Tu monitor va a $($script:MonitorHz) Hz. Con Reflex, mejor sin límite. Sin Reflex, unos FPS por debajo: por ejemplo, $([int]$script:MonitorHz - 10)."
} else { 'Con Reflex, mejor sin límite. Sin Reflex, unos FPS por debajo de los Hz del monitor.' }
Write-ZLog 'Z. Optimizer listo. Todo lo que cambies se puede deshacer en Restaurar.' head
$timer.Start()
[void]$window.ShowDialog()
$timer.Stop()
