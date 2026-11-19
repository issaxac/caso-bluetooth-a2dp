<#
.SYNOPSIS
    Diagnóstico de audio Bluetooth en Windows 11 (solo lectura).

.DESCRIPTION
    Comprueba si el sistema sufre el fallo "auriculares conectados pero sin
    audio": perfiles Bluetooth en [OK], pero sin endpoints de audio.
    Detecta filtros de audio OEM (btath_audio_flt.inf y similares) y servicios
    inexistentes (AthBTPort / BthAudioFlt).

    ESTE SCRIPT NO MODIFICA NADA. Solo lee estado y muestra un veredicto.

.PARAMETER Mac
    MAC del auricular sin separadores, por ejemplo AABBCCDDEEFF.
    Si se omite, se listan todos los dispositivos Bluetooth.

.PARAMETER OutFile
    Ruta donde guardar el informe en texto. Si se omite, solo se muestra
    por pantalla.

.EXAMPLE
    .\diagnostico.ps1

.EXAMPLE
    .\diagnostico.ps1 -Mac AABBCCDDEEFF -OutFile "$env:USERPROFILE\Desktop\bt-diag.txt"

.NOTES
    Parte del repositorio caso-bluetooth-a2dp (CC BY 4.0).
    Algunas secciones requieren PowerShell como administrador.
#>

[CmdletBinding()]
param(
    [string]$Mac = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$script:Informe = New-Object System.Text.StringBuilder
$script:Hallazgos = New-Object System.Collections.Generic.List[string]

function Linea {
    param([string]$Texto = '')
    Write-Host $Texto
    [void]$script:Informe.AppendLine($Texto)
}

function Seccion {
    param([string]$Titulo)
    Linea ''
    Linea ('=' * 68)
    Linea "  $Titulo"
    Linea ('=' * 68)
}

function Dato {
    param([string]$Etiqueta, $Valor)
    Linea ('  {0,-34} {1}' -f $Etiqueta, $Valor)
}

function Aviso {
    param([string]$Texto)
    Write-Host "  [!] $Texto" -ForegroundColor Yellow
    [void]$script:Informe.AppendLine("  [!] $Texto")
    [void]$script:Hallazgos.Add($Texto)
}

function Bien {
    param([string]$Texto)
    Write-Host "  [OK] $Texto" -ForegroundColor Green
    [void]$script:Informe.AppendLine("  [OK] $Texto")
}

function Nota {
    param([string]$Texto)
    Write-Host "  [-] $Texto" -ForegroundColor DarkYellow
    [void]$script:Informe.AppendLine("  [-] $Texto")
}

# --------------------------------------------------------------------------
# 0. Contexto
# --------------------------------------------------------------------------
$esAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $esAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$macLimpia = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()

Seccion '0. CONTEXTO'
if ($os) {
    Dato 'Sistema' "$($os.Caption)"
    Dato 'Version / build' "$($os.Version)  (build $($os.BuildNumber))"
    Dato 'RAM visible' ('{0:N2} GB' -f ($os.TotalVisibleMemorySize / 1MB))
}
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
if ($bios) { Dato 'BIOS' "$($bios.SMBIOSBIOSVersion)" }
Dato 'Usuario' $env:USERNAME
Dato 'PowerShell elevado' $esAdmin
Dato 'Filtro por MAC' $(if ($macLimpia) { $macLimpia } else { '(ninguno: se listan todos)' })
Dato 'Fecha del informe' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# --------------------------------------------------------------------------
# 1. Radios Bluetooth
# --------------------------------------------------------------------------
Seccion '1. ADAPTADORES BLUETOOTH'
$radios = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.InstanceId -notmatch '^(BTHENUM|BTHLE|RFCOMM)\\') -and
        ($_.InstanceId -notmatch '^BTH\\MS_')
    })
if ($radios.Count -eq 0) {
    Aviso 'No se encontro ningun adaptador Bluetooth visible (puede estar deshabilitado).'
} else {
    foreach ($r in $radios) {
        Linea ("  [{0}] {1}" -f $r.Status, $r.FriendlyName)
        Linea ("        InstanceId: {0}" -f $r.InstanceId)
        try {
            $drv = Get-PnpDeviceProperty -InstanceId $r.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop
            if ($drv.Data) { Linea ("        Driver:     {0}" -f $drv.Data) }
        } catch { }
        try {
            $inf = Get-PnpDeviceProperty -InstanceId $r.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
            if ($inf.Data) { Linea ("        INF:        {0}" -f $inf.Data) }
        } catch { }
    }
}

# --------------------------------------------------------------------------
# 2. Nodos del dispositivo (perfiles A2DP / AVRCP / HFP / SPP)
# --------------------------------------------------------------------------
Seccion '2. NODOS DEL DISPOSITIVO'
$perfiles = [ordered]@{
    '0000110B' = 'A2DP Sink  (audio de alta calidad)'
    '0000110A' = 'A2DP Source'
    '0000110C' = 'AVRCP      (control multimedia)'
    '0000111E' = 'Handsfree  (manos libres)'
    '00001101' = 'SPP        (puerto serie)'
}

$todos = @(Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'BTHENUM|BTHLE' })
$objetivo = $todos
if ($macLimpia) {
    $objetivo = @($todos | Where-Object { $_.InstanceId -match $macLimpia })
    if ($objetivo.Count -eq 0) {
        Aviso "No se encontro ningun nodo Bluetooth con la MAC $macLimpia. Revisa la MAC o vuelve a emparejar."
    }
}

if ($objetivo.Count -eq 0 -and -not $macLimpia) {
    Aviso 'No hay nodos Bluetooth enumerados. Empareja el dispositivo y repite.'
} else {
    foreach ($guid in $perfiles.Keys) {
        $nodos = @($objetivo | Where-Object { $_.InstanceId -match $guid })
        if ($nodos.Count -eq 0) { continue }
        Linea ''
        Linea ("  {0}  ({1})" -f $perfiles[$guid], $guid)
        foreach ($n in $nodos) {
            Linea ("     [{0}] {1}" -f $n.Status, $n.FriendlyName)
            try {
                $inf = Get-PnpDeviceProperty -InstanceId $n.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
                if ($inf.Data) { Linea ("           INF vinculado: {0}" -f $inf.Data) }
            } catch { }
            try {
                $svc = Get-PnpDeviceProperty -InstanceId $n.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop
                $v = if ($svc.Data) { $svc.Data } else { '(ninguno)' }
                Linea ("           Servicio:       {0}" -f $v)
                if ($guid -eq '0000110B' -and (-not $svc.Data)) {
                    Aviso "El nodo A2DP $($n.InstanceId) no tiene servicio asignado (patron BTNULL)."
                }
            } catch { }
        }
    }
    if (-not ($objetivo | Where-Object { $_.InstanceId -match '0000110B' })) {
        Aviso 'No se encontro el nodo A2DP (0000110B). Sin el, no puede haber audio de alta calidad.'
    }
}

# --------------------------------------------------------------------------
# 3. Endpoints de audio
# --------------------------------------------------------------------------
Seccion '3. ENDPOINTS DE AUDIO'
$ep = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue)
$media = @(Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue)
Dato 'Dispositivos AudioEndpoint' $ep.Count
Dato 'Dispositivos MEDIA' $media.Count
Linea ''
if ($ep.Count -eq 0) {
    Aviso 'No existe NINGUN endpoint de audio. Windows no llego a crear la salida de sonido.'
} else {
    foreach ($e in $ep) { Linea ("  [{0}] {1}" -f $e.Status, $e.FriendlyName) }
}
if ($media.Count -gt 0) {
    Linea ''
    Linea '  Clase MEDIA:'
    foreach ($m in $media) { Linea ("  [{0}] {1}" -f $m.Status, $m.FriendlyName) }
}

# --------------------------------------------------------------------------
# 4. Servicios implicados
# --------------------------------------------------------------------------
Seccion '4. SERVICIOS'
$servicios = [ordered]@{
    'BthServ'         = @('BthServ')
    'BthA2dp'         = @('BthA2dp')
    'AVRCP'           = @('BthAvrcpTg', 'Microsoft_Bluetooth_AvrcpTransport')
    'Handsfree'       = @('BthHFEnum')
    'Enumerator'      = @('BthEnum')
    'OEM: AthBTPort'  = @('AthBTPort')
    'OEM: BthAudioFlt'= @('BthAudioFlt')
}
foreach ($clave in $servicios.Keys) {
    $alternativas = $servicios[$clave]
    $encontrado = $null
    $nombreReal = $null
    foreach ($alt in $alternativas) {
        $sv = Get-Service -Name $alt -ErrorAction SilentlyContinue
        if ($sv) { $encontrado = $sv; $nombreReal = $alt; break }
    }
    if ($encontrado) {
        Linea ('  {0,-18} {1,-10} inicio: {2}   ({3})' -f $clave, $encontrado.Status, $encontrado.StartType, $nombreReal)
    } else {
        Linea ('  {0,-18} (no existe)' -f $clave)
        if ($clave -like 'OEM:*') {
            Nota "Servicio OEM ausente. Es normal en un sistema sano; solo importa si un INF lo referencia."
        } else {
            Aviso "Falta el servicio '$clave'. Es parte del soporte Bluetooth nativo de Windows."
        }
    }
}

# --------------------------------------------------------------------------
# 5. Paquetes de driver instalados
# --------------------------------------------------------------------------
Seccion '5. PAQUETES DE DRIVER'
if (-not $esAdmin) {
    Linea '  (omitido: pnputil /enum-drivers requiere elevacion)'
    Nota 'Ejecuta de nuevo como administrador para revisar los paquetes OEM.'
} else {
    # pnputil escribe con la pagina de codigos OEM: se ajusta para no perder acentos.
    $cpOriginal = $null
    try {
        $cpOriginal = [Console]::OutputEncoding
        $oem = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding($oem)
    } catch { }
    $raw = & pnputil /enum-drivers 2>$null
    try { if ($cpOriginal) { [Console]::OutputEncoding = $cpOriginal } } catch { }

    if (-not $raw) {
        Aviso 'pnputil no devolvio resultados.'
    } else {
        $bloques = (($raw -join "`n") -split "(`r?`n){2,}")
        $sospechosos = @()
        $encontrados = 0

        foreach ($b in $bloques) {
            if ($b -notmatch '(?i)bluetooth|btath|btusb|atheros') { continue }

            # Se extraen los .inf por patron, sin depender de las etiquetas traducidas.
            $infs = @([regex]::Matches($b, '(?i)\b[\w\-\+]+\.inf\b') | ForEach-Object { $_.Value })
            $publicado = $infs | Where-Object { $_ -match '(?i)^oem\d+\.inf$' } | Select-Object -First 1
            $original = $infs | Where-Object { $_ -notmatch '(?i)^oem\d+\.inf$' } | Select-Object -First 1

            $version = ''
            if ($b -match '(\d+\.\d+\.\d+\.\d+)') { $version = $Matches[1] }
            $fecha = ''
            if ($b -match '(\d{1,2}/\d{1,2}/\d{4})') { $fecha = $Matches[1] }

            $encontrados++
            Linea ''
            Linea ("  --- {0}" -f $(if ($publicado) { $publicado } else { '(sin nombre publicado)' }))
            if ($original) { Linea ("      INF original: {0}" -f $original) }
            if ($version) { Linea ("      Version:      {0}" -f $version) }
            if ($fecha) { Linea ("      Fecha:        {0}" -f $fecha) }

            if (($original -match '(?i)audio_flt') -or ($b -match '(?i)audio_flt')) {
                $sospechosos += $(if ($publicado) { $publicado } else { $original })
                Aviso ("Paquete de FILTRO DE AUDIO OEM detectado: {0} ({1})." -f $publicado, $original)
            }
        }

        if ($encontrados -eq 0) {
            Nota 'No se encontro ningun paquete de driver con relacion Bluetooth.'
        }
        Linea ''
        if ($sospechosos.Count -gt 0) {
            Aviso ('Candidato a eliminar: ' + (($sospechosos | Where-Object { $_ }) -join ', ') +
                   '  ->  pnputil /delete-driver <nombre> /uninstall /force')
        } else {
            Bien 'No se detecto el filtro de audio OEM btath_audio_flt.inf.'
        }
    }
}

# --------------------------------------------------------------------------
# 6. Driver A2DP realmente bindeado
# --------------------------------------------------------------------------
Seccion '6. DRIVER A2DP ACTIVO'
$a2dp = @($todos | Where-Object { $_.InstanceId -match '0000110B' })
if ($a2dp.Count -eq 0) {
    Linea '  (sin nodo A2DP que inspeccionar)'
} else {
    foreach ($n in $a2dp) {
        try {
            $inf = Get-PnpDeviceProperty -InstanceId $n.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
            $d = if ($inf.Data) { $inf.Data } else { '(desconocido)' }
            Linea ("  [{0}] {1}" -f $n.Status, $n.FriendlyName)
            Linea ("        INF: {0}" -f $d)
            if ($d -match 'btath_audio_flt') {
                Aviso 'El nodo A2DP esta capturado por el filtro OEM, no por el driver nativo de Windows.'
            } elseif ($d -match 'microsoft_bluetooth_a2dp|bth.inf') {
                Bien 'El nodo A2DP usa el driver nativo de Windows.'
            }
        } catch { }
    }
}

# --------------------------------------------------------------------------
# 7. Veredicto
# --------------------------------------------------------------------------
Seccion '7. VEREDICTO'
$tieneA2dp = [bool]($todos | Where-Object { $_.InstanceId -match '0000110B' })
$tieneEndpoints = $ep.Count -gt 0

if ($tieneA2dp -and -not $tieneEndpoints) {
    Linea '  PATRON DEL CASO: perfiles Bluetooth enumerados pero SIN endpoint de audio.'
    Linea '  -> Un filtro de audio OEM (o un nodo A2DP sin servicio) impide crear la salida.'
    Linea '  -> Siguiente paso: revisar la seccion 5 y aplicar el procedimiento del README.'
} elseif ($tieneEndpoints) {
    Linea '  Hay al menos un endpoint de audio en el sistema.'
    Linea '  Si tu auricular no aparece en Sonido, revisa que el nodo A2DP (0000110B)'
    Linea '  exista y que su INF sea microsoft_bluetooth_a2dp_src.inf.'
} else {
    Linea '  No hay nodos A2DP ni endpoints: el dispositivo no esta emparejado o el'
    Linea '  adaptador Bluetooth esta deshabilitado. Empareja primero.'
}

Linea ''
if ($script:Hallazgos.Count -eq 0) {
    Linea '  Sin hallazgos negativos.'
} else {
    Linea ("  Hallazgos que requieren atencion: {0}" -f $script:Hallazgos.Count)
    $i = 0
    foreach ($h in $script:Hallazgos) { $i++; Linea ("   {0}. {1}" -f $i, $h) }
}

Linea ''
Linea '  NOTA: el estado [Unknown] en AudioEndpoint es normal; no indica fallo.'
Linea '  Este script no ha modificado nada en el sistema.'

# --------------------------------------------------------------------------
# Guardar informe
# --------------------------------------------------------------------------
if ($OutFile) {
    try {
        $script:Informe.ToString() | Out-File -FilePath $OutFile -Encoding UTF8 -Force
        Write-Host ''
        Write-Host "Informe guardado en: $OutFile" -ForegroundColor Cyan
    } catch {
        Write-Host "No se pudo guardar el informe: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'Diagnostico completado.' -ForegroundColor Cyan
