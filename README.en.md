# Bluetooth headphones "connected" but no audio on Windows 11 — the OEM audio filter with a null service

> **Real, reproducible case.** The headphones pair, every Bluetooth profile reports `[OK]`, and yet Windows **never creates an audio output device**.
>
> The cause was not the headphones, not the radio, not the pairing: an **OEM audio filter** was capturing the A2DP nodes and pointing them at a **service that does not exist** (`BTNULL`).

---

## TL;DR

| Item | Value |
|---|---|
| OS | Windows 11 Pro, build **26200** (25H2) |
| Hardware | Laptop with **Qualcomm Atheros QCA9377** Wi-Fi/BT combo |
| Broken driver package | OEM DCH **10.0.0.1272** → `oem63.inf` (`btath_audio_flt.inf`, Dec 2023) |
| Working driver | **10.0.0.953** → `oem42.inf` (2020) |
| Driver Windows bound afterwards | `microsoft_bluetooth_a2dp_src.inf` (`BthA2dp`) |
| Endpoints that appeared | *Headphones (BT)* · *Headset (BT Hands-Free)* |

**One-line fix:** remove the OEM package that installs the audio filter and let Windows use its native A2DP driver.

---

## Repository contents

| File | Contents |
|---|---|
| `README.md` | Full case, Spanish |
| `README.en.md` | This document (English) |
| `scripts/diagnostico.ps1` | Automated **read-only** diagnosis with a verdict |
| `LICENSE` | CC BY 4.0 |

---

## 1. Symptoms

- Headphones appear in **Settings → Bluetooth & devices** and pair without errors.
- In **Device Manager → Bluetooth** these nodes are `[OK]`:
  - `BT Hands-Free AG`
  - `BT AVRCP Transport`
  - `Standard Serial over Bluetooth link (COM4)`
- Class **MEDIA** shows `BT` and `BT Hands-Free`, also `[OK]`.
- **But class `AudioEndpoint` is empty** (or entries sit in `[Unknown]` state).
- Windows sound output list **has no "Headphones"**.

> That contrast — perfect profile nodes, zero audio endpoints — is the key clue. If the headphones were the problem, the profiles would not be `[OK]`.

---

## 2. Diagnosis (commands)

All commands are **read-only**.

> 💡 **Ready-made script:** [`scripts/diagnostico.ps1`](scripts/diagnostico.ps1) runs every check below and prints a verdict. It changes nothing.
>
> ```powershell
> .\scripts\diagnostico.ps1
> .\scripts\diagnostico.ps1 -Mac AABBCCDDEEFF -OutFile "$env:USERPROFILE\Desktop\bt-diag.txt"
> ```
>
> Running it **as administrator** adds the OEM package review (`pnputil /enum-drivers`), where the `btath_audio_flt.inf` suspect shows up.

```powershell
# Replace AABBCCDDEEFF with your headphones' MAC, without colons
Get-PnpDevice | Where-Object { $_.InstanceId -match 'AABBCCDDEEFF' } |
    Select-Object Status, Class, FriendlyName, InstanceId | Format-List

Get-PnpDevice -Class AudioEndpoint | Select-Object Status, FriendlyName
Get-PnpDevice -Class MEDIA         | Select-Object Status, FriendlyName

# The smoking gun: services the filter expects but that do not exist
Get-Service AthBTPort, BthAudioFlt -ErrorAction SilentlyContinue

# Which driver packages are installed
pnputil /enum-drivers
```

Look for a published INF whose *original name* is `btath_audio_flt.inf`:

```
Original INF name: btath_audio_flt.inf
Published INF name: oem63.inf
Class: Bluetooth
Version: 12/2023
```

That `.inf` is an **audio filter**, not a radio driver.

---

## 3. Root cause

The 2023 DCH package installs **two different things**:

1. A Bluetooth **radio driver**
2. An **audio filter** (`btath_audio_flt.inf`) attached as an *upper filter* on `BTHENUM` nodes

The install section declares the A2DP nodes with a **`BTNULL`** service — meaning *no service at all*. And the services the filter expects (`AthBTPort`, `BthAudioFlt`) were **never registered**.

Chain of events:

```
Headphones paired
        ↓
Windows enumerates profiles (A2DP, AVRCP, HFP)   ← all [OK]
        ↓
OEM filter captures the A2DP node
        ↓
Node is left with a BTNULL (null) service
        ↓
No function driver creates the audio endpoint
        ↓
Sound settings: no "Headphones"                  ← the symptom
```

**Why the usual forum advice fails:**

| Common "fix" | Why it fails here |
|---|---|
| Unpair and re-pair | The filter reattaches as soon as the node re-enumerates |
| Remove device in Settings | Deletes pairing only, not the filter |
| Restart the Bluetooth service | The filter does not depend on the radio service |
| Audio troubleshooter | Looks for endpoints that do not exist; cannot create them |
| Reinstall the OEM package | **Makes it worse**: reinstalls the filter |

---

## 4. Fix, step by step

> ⚠️ **Before anything:** create a **restore point**. You are removing a driver package.

```powershell
# Elevated PowerShell
Checkpoint-Computer -Description "Before Bluetooth audio repair" -RestorePointType MODIFY_SETTINGS
```

### Step 1 — Find the filter's `oemNN.inf`

```powershell
pnputil /enum-drivers | Select-String -Pattern 'btath_audio|audio_flt' -Context 6,2
```

### Step 2 — Remove the OEM filter

```powershell
pnputil /delete-driver oem63.inf /uninstall /force
```

If it fails because the device is in use: disconnect the headphones, turn Bluetooth off, retry.

### Step 3 — Roll back the radio driver

**Option A — Device Manager (recommended):**

1. Device Manager → **Bluetooth**
2. Right-click the adapter → **Properties** → **Driver** tab
3. **Roll Back Driver**

**Option B — if the button is greyed out:**

1. Properties → **Update driver**
2. **Browse my computer for drivers**
3. **Let me pick from a list of available drivers on my computer**
4. Select the **older** version (`10.0.0.953`, 2020 in this case)
5. Next → Reboot

**Option C — install the old INF manually:**

```powershell
pnputil /add-driver "C:\path\to\old-driver\btath.inf" /install
```

### Step 4 — Reboot

### Step 5 — Reconnect the headphones

With no filter present, Windows binds its native A2DP driver:

```
microsoft_bluetooth_a2dp_src.inf  →  BthA2dp
```

That driver **does** create the audio endpoint.

---

## 5. Verification

```powershell
Get-PnpDevice -Class AudioEndpoint | Select-Object Status, FriendlyName
Get-PnpDevice | Where-Object { $_.InstanceId -match 'AABBCCDDEEFF' } | Select-Object Status, FriendlyName
pnputil /enum-drivers | Select-String 'btath_audio'
```

Expected:

```text
OUTPUT [Unknown] Headphones (BT)
OUTPUT [Unknown] Headset (BT Hands-Free)
```

> 💡 **Do not panic if the `AudioEndpoint` status reads `[Unknown]`.** PnP does not report a meaningful state for that enumerator even when the device works. The real test: the headphones appear in **Settings → System → Sound** and audio plays.

---

## 6. What NOT to do

- ❌ **Do not reinstall the 2023 OEM package** (or any package containing `btath_audio_flt.inf`).
- ❌ Do not run automatic "update all drivers" tools: they reinstall the filtered package.
- ❌ Do not remove the device in Settings expecting a fix: it never touches the filter.
- ❌ Do not test with a second pair of headphones: the filter is global and will break those too.

## 7. How to revert

```powershell
# Elevated — reinstalls the original package
pnputil /add-driver "C:\path\Bluetooth_DCH_QualcommAtheros\btath_audio_flt.inf" /install
```

Or run the original OEM installer. **Do this only if strictly necessary.**

---

## 8. FAQ

**Do I lose anything by using the 2020 driver?**
No functional difference in this case: audio, AVRCP, hands-free and COM4 all stay `[OK]`. What you lose is the OEM audio filter — the very component that was broken.

**Does it affect Wi-Fi?**
No. Only the Bluetooth side of the combo is touched.

**Does this apply to other vendors?**
Yes. **Any** OEM package that installs a Bluetooth audio *upper filter* referencing missing services produces the same symptom. INF names change; the mechanics do not.

**The AudioEndpoint still does not show up — now what?**

```powershell
Get-Service BthA2dp, BthAvrcpTg, BthHFEnum
```

Check that the bound driver is `BthA2dp` (not only `BthHFEnum`).

---

## 9. Transparency

This case was diagnosed in a session assisted by **an AI agent (OpenCode) running a language model**, under human supervision: the agent proposed and ran read-only commands, the user approved every system change and validated the result with real audio.

If you publish or adapt this document, please cite the source.

## License

[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
