# Auriculares Bluetooth "conectados" pero sin audio en Windows 11 — el filtro de audio OEM con servicio nulo

> **Caso real, reproducible.** Los auriculares se emparejan, todos los perfiles reportan `[OK]`, y sin embargo Windows **no crea ningún dispositivo de salida de audio**.
>
> La causa no era el auricular, ni el radio Bluetooth, ni el emparejamiento: era un **filtro de audio OEM** que capturaba los nodos A2DP y los dejaba apuntando a un **servicio que no existe** (`BTNULL`).

---

## TL;DR

| Dato | Valor |
|---|---|
| Sistema | Windows 11 Pro, build **26200** (25H2) |
| Equipo | Portátil con combo Wi-Fi/BT **Qualcomm Atheros QCA9377** |
| Driver con el fallo | Paquete DCH OEM **10.0.0.1272** → `oem63.inf` (`btath_audio_flt.inf`, dic-2023) |
| Driver que sí funciona | **10.0.0.953** → `oem42.inf` (2020) |
| Driver que Windows acabó bindeando | `microsoft_bluetooth_a2dp_src.inf` (`BthA2dp`) |
| Endpoints que aparecieron | *Auriculares (BT)* · *Auriculares con micrófono (BT Hands-Free)* |
| Tiempo de diagnóstico | ~1 sesión (medición → hipótesis → descarte → causa raíz) |

**Solución en una línea:** quitar el paquete OEM que instala el filtro de audio y dejar que Windows use su propio driver A2DP.

---

## Contenido del repositorio

| Archivo | Qué contiene |
|---|---|
| `README.md` | Este documento: caso completo (español) |
| `README.en.md` | English version |
| `scripts/diagnostico.ps1` | Diagnóstico automático, **solo lectura**, con veredicto |
| `LICENSE` | CC BY 4.0 |

---

## 1. Síntomas

- Los auriculares aparecen en **Configuración → Bluetooth y dispositivos** y se emparejan sin error.
- En el **Administrador de dispositivos → Bluetooth** estos nodos están en `[OK]`:
  - `BT Hands-Free AG`
  - `BT Transporte AVRCP`
  - `Serie estándar sobre el vínculo Bluetooth (COM4)`
- En la clase **MEDIA** aparecen `BT` y `BT Hands-Free`, también `[OK]`.
- **Pero en la clase `AudioEndpoint` no hay nada** (o hay entradas en estado `[Unknown]`).
- En el selector de sonido de Windows **no existe** "Auriculares".

> Ese contraste — perfiles del dispositivo perfectos, cero endpoints de audio — es la pista central. Si el problema fuera el auricular, los perfiles no estarían `[OK]`.

---

## 2. Diagnóstico (comandos)

Todos los comandos son de **solo lectura**. Ejecuta PowerShell normal (no hace falta administrador para diagnosticar).

> 💡 **Script listo para usar:** [`scripts/diagnostico.ps1`](scripts/diagnostico.ps1) ejecuta todas estas comprobaciones y emite un veredicto. No modifica nada.
>
> ```powershell
> # Diagnóstico general
> .\scripts\diagnostico.ps1
>
> # Solo un dispositivo, y guardando el informe
> .\scripts\diagnostico.ps1 -Mac AABBCCDDEEFF -OutFile "$env:USERPROFILE\Desktop\bt-diag.txt"
> ```
>
> Si lo ejecutas **como administrador** añade la revisión de paquetes OEM (`pnputil /enum-drivers`), que es donde aparece el sospechoso `btath_audio_flt.inf`.

### 2.1 ¿Qué nodos existen para el auricular?

```powershell
# Reemplaza AABBCCDDEEFF por la MAC de tu auricular SIN dos puntos
Get-PnpDevice | Where-Object { $_.InstanceId -match 'AABBCCDDEEFF' } |
    Select-Object Status, Class, FriendlyName, InstanceId | Format-List
```

Un dispositivo sano muestra los nodos de perfil:

| GUID | Perfil |
|---|---|
| `{0000110B}` | A2DP Sink (audio de alta calidad) |
| `{0000110C}` | AVRCP (control multimedia) |
| `{0000111E}` | Handsfree (manos libres) |
| `{00001101}` | SPP (puerto serie) |

### 2.2 ¿Hay endpoints de audio?

```powershell
Get-PnpDevice -Class AudioEndpoint | Select-Object Status, FriendlyName
Get-PnpDevice -Class MEDIA        | Select-Object Status, FriendlyName
```

Si `AudioEndpoint` está vacío → **Windows no llegó a crear la salida de audio**. Ese es el fallo.

### 2.3 ¿Existe el servicio que el filtro necesita?

Aquí está la clave del caso:

```powershell
Get-Service AthBTPort, BthAudioFlt -ErrorAction SilentlyContinue
```

En este equipo ambos devolvían **vacío**: los servicios **no existían**, pero el filtro OEM los referenciaba. Eso es una inconsistencia del paquete, no un problema del auricular.

### 2.4 ¿Qué paquetes de driver hay instalados?

```powershell
pnputil /enum-drivers
```

Busca los que tengan `bluetooth` y `audio` en el nombre original. En este caso:

```
Nombre del INF original: btath_audio_flt.inf
Nombre del INF publicado: oem63.inf
Proveedor: Qualcomm Atheros Communications
Clase: Bluetooth
Versión: 12/2023
```

Ese `.inf` es un **filtro de audio**, no un controlador de radio.

### 2.5 ¿Cuál es el driver de radio activo?

```powershell
Get-PnpDevice -Class Bluetooth | Where-Object { $_.FriendlyName -match 'Qualcomm|Atheros|QCA' } |
    Select-Object FriendlyName, Status, InstanceId

# Ver versiones disponibles del driver
pnputil /enum-drivers | Select-String -Pattern 'oem|bt' -Context 0,4
```

---

## 3. Causa raíz

El paquete DCH de 2023 instala **dos cosas distintas**:

1. Un **driver de radio** Bluetooth (`btath...`)
2. Un **filtro de audio** (`btath_audio_flt.inf`) que se engancha como *upper filter* sobre los nodos `BTHENUM`.

El problema: la sección de instalación de ese filtro define los nodos A2DP con un servicio **`BTNULL`** — es decir, *ningún servicio*. Y los servicios que ese filtro espera (`AthBTPort`, `BthAudioFlt`) **no se registraron** en el sistema.

Resultado:

```
Auriculares emparejados
        ↓
Windows enumera los perfiles (A2DP, AVRCP, HFP)   ← todos [OK]
        ↓
El filtro OEM captura el nodo A2DP
        ↓
El nodo queda con servicio BTNULL (nulo)
        ↓
Ningún driver de función crea el endpoint de audio
        ↓
Sound settings: no existe "Auriculares"          ← el síntoma
```

**Por qué las soluciones típicas de los foros no funcionan:**

| "Solución" habitual | Por qué falla aquí |
|---|---|
| Quitar y volver a emparejar | El filtro se reengancha en cuanto se reenumera el nodo |
| Desinstalar el dispositivo desde Configuración | Solo borra el emparejamiento, no el filtro |
| Reiniciar el servicio Bluetooth | El filtro no depende del servicio de radio |
| Solucionador de problemas de audio | Busca endpoints inexistentes; no puede crearlos |
| Reinstalar el paquete OEM | **Empeora**: vuelve a instalar el filtro |

Por eso el problema "sobrevive" a varios técnicos: todos atacan la capa equivocada (el emparejamiento) cuando el fallo está en la capa de *driver filters*.

---

## 4. Solución paso a paso

> ⚠️ **Antes de tocar nada:** crea un **punto de restauración** y, si puedes, un respaldo del DriverStore. Vas a desinstalar un paquete de driver.

### Paso 0 — Punto de restauración

```powershell
# PowerShell como administrador
Checkpoint-Computer -Description "Antes de reparar audio Bluetooth" -RestorePointType MODIFY_SETTINGS
```

### Paso 1 — Identifica el `oemNN.inf` del filtro

```powershell
pnputil /enum-drivers | Select-String -Pattern 'btath_audio|audio_flt' -Context 6,2
```

Apunta el nombre publicado (por ejemplo `oem63.inf`).

### Paso 2 — Elimina el filtro OEM

```powershell
# Administrador
pnputil /delete-driver oem63.inf /uninstall /force
```

Si da error porque el dispositivo está en uso: desconecta los auriculares, apaga el Bluetooth y repite.

### Paso 3 — Baja (rollback) el driver de radio

**Opción A — desde el Administrador de dispositivos (recomendada):**

1. Administrador de dispositivos → **Bluetooth**
2. Clic derecho en el adaptador (Qualcomm/Atheros) → **Propiedades** → pestaña **Controlador**
3. **Revertir al controlador anterior** (si está disponible)

**Opción B — si el botón está en gris:**

1. Propiedades → **Actualizar controlador**
2. **Buscar controladores en mi equipo**
3. **Elegir de una lista de controladores disponibles en mi equipo**
4. Selecciona la versión **anterior** (en este caso `10.0.0.953`, año 2020)
5. Siguiente → Reiniciar

**Opción C — instalación manual del INF antiguo:**

```powershell
# Administrador
pnputil /add-driver "C:\ruta\al\driver-antiguo\btath.inf" /install
```

### Paso 4 — Reinicia

```powershell
Restart-Computer
```

### Paso 5 — Vuelve a emparejar los auriculares

Al no existir ya el filtro, Windows bindea su propio driver A2DP:

```
microsoft_bluetooth_a2dp_src.inf  →  BthA2dp
```

Ese driver **sí** crea el endpoint de audio.

---

## 5. Verificación

```powershell
# 1. Debe aparecer al menos un endpoint nuevo
Get-PnpDevice -Class AudioEndpoint | Select-Object Status, FriendlyName

# 2. Los perfiles deben seguir OK
Get-PnpDevice | Where-Object { $_.InstanceId -match 'AABBCCDDEEFF' } |
    Select-Object Status, FriendlyName

# 3. El filtro OEM ya no debe estar
pnputil /enum-drivers | Select-String 'btath_audio'
```

Resultado esperado:

```text
SALIDA [Unknown] Auriculares (BT)
SALIDA [Unknown] Auriculares con micrófono (BT Hands-Free)
```

> 💡 **No te asustes si el estado del `AudioEndpoint` sale `[Unknown]`.** PnP no reporta un estado significativo para ese enumerador aunque el dispositivo funcione perfectamente. La prueba real es que el auricular aparezca en **Configuración → Sistema → Sonido** y suene.

Prueba final: reproduce audio y verifica que el medidor de nivel de la salida se mueva.

---

## 6. Qué NO hacer

- ❌ **No reinstales el paquete OEM de 2023** (o el que contenga `btath_audio_flt.inf`). Vuelve a romperlo, y a veces el filtro queda "pegado" aunque desinstales.
- ❌ No uses "actualizar todos los drivers" automáticos: reinstalan el paquete con el filtro.
- ❌ No borres el dispositivo desde Configuración esperando que se arregle: no toca el filtro.
- ❌ No emparejes un segundo auricular para "probar": el filtro es global, también lo romperá.

## 7. Cómo revertir (si necesitas el paquete OEM)

```powershell
# Administrador — reinstala el paquete original
pnputil /add-driver "C:\ruta\Bluetooth_DCH_QualcommAtheros\btath_audio_flt.inf" /install
```

O simplemente ejecuta el instalador OEM original. **No lo hagas si no es imprescindible.**

---

## 8. Preguntas frecuentes

**¿Pierdo rendimiento o funciones usando el driver de 2020?**
En este caso no se notó ninguna diferencia funcional (audio, AVRCP, manos libres y COM4 siguen `[OK]`). Lo que se pierde es el filtro de audio OEM, que era precisamente el que fallaba.

**¿Afecta al Wi-Fi?**
No. Solo se toca el driver Bluetooth del combo. El adaptador Wi-Fi tiene su propio paquete.

**¿Esto sirve para otros fabricantes?**
El patrón se repite: **cualquier** paquete OEM que instale un *upper filter* de audio Bluetooth con referencias a servicios inexistentes produce este mismo síntoma. Cambian los nombres de los `.inf`, no la mecánica.

**¿Y si después de todo el AudioEndpoint sigue sin aparecer?**
Comprueba que el driver bindeado sea `BthA2dp` (no `BthHFEnum` solamente) y que los servicios `BthA2dp`/`BthAvrcpTg` existan:

```powershell
Get-Service BthA2dp, BthAvrcpTg, BthHFEnum
```

---

## 9. Transparencia

Este caso se diagnosticó en una sesión asistida por **un agente de IA (OpenCode) con un modelo de lenguaje**, bajo supervisión humana: el agente propuso y ejecutó los comandos de lectura, el usuario aprobó cada cambio de sistema y validó el resultado con audio real.

Si publicas o adaptas este documento, cita la fuente. El objetivo es que quien llegue aquí con el mismo síntoma no pierda semanas.

## Licencia

[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.es) — puedes copiar, adaptar y redistribuir citando la fuente.
