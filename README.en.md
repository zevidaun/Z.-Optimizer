<p align="center">
  <img src="assets/banner.png" alt="Z. Optimizer" width="100%">
</p>

# Z. Optimizer (English)

**A Windows 11 optimizer you can read end to end before running it.**
One PowerShell script, no binaries, no downloads, and a button to undo everything.

> The app interface is in Spanish. [Versión en español →](README.md)

## Why

The "PC optimizer" scene is full of smoke: closed paid tools promising +200 FPS, unsigned `.exe` files asking for admin rights, tweak packs that disable Defender and Windows Update and, at worst, **backdoors, miners and botnets** hidden behind a *Boost* button.

Z. Optimizer is the opposite:

- **Open and readable.** The whole program is [`Z-Optimizer.ps1`](Z-Optimizer.ps1). No `.exe`, no DLLs, no obfuscation, no Base64.
- **Zero network connections.** It downloads nothing, phones home for nothing, collects nothing.
- **Fully reversible.** Every original value is journaled before it changes and can be restored from the **Restaurar** tab. A system restore point is created too.
- **No magic promises.** Every tweak says what it does, and says so when the effect is small or debated.

## What it does

- **Privacy:** telemetry at its minimum, no advertising ID or activity history, `DiagTrack` disabled.
- **UI:** no ads or suggested apps, no Bing in Start search, no Widgets; optionally no Copilot / Recall / Click to Do.
- **Performance & gaming:** Game Mode, HAGS, no Game DVR or Power Throttling, raw mouse input, custom **Z. Plan** power plan.
- **Cleanup & debloat** *(optional)*: temp files, `DISM` component cleanup, TRIM, removal of preinstalled apps (Store, Xbox, Photos and Calculator are kept).
- **20 verified `.reg` tweaks**, each with its revert file and exportable to disk.
- **Fortnite profiles** for Performance mode (DX11), editing only the needed keys of `GameUserSettings.ini` with automatic backups.

## What it does NOT do

- No Internet access, no `irm … | iex`.
- Does not disable **Defender**, **SmartScreen**, **UAC** or **Windows Update**.
- Installs no services, scheduled tasks, drivers or programs.

## Install

1. **Code → Download ZIP** (or grab the latest *Release*) and extract it.
2. *(Recommended)* Read `Z-Optimizer.ps1`.
3. Double-click **`Iniciar Z. Optimizer.bat`** and accept the admin prompt.

Tip: tick **"Solo simular"** (dry run) in the Optimizador tab to see every change without applying it.

**Requirements:** Windows 11 24H2 / 25H2 / 26H2 · Windows PowerShell 5.1 · admin account.

## Audit it yourself

```powershell
Select-String -Path .\Z-Optimizer.ps1 -Pattern 'Invoke-WebRequest|Invoke-RestMethod|WebClient|HttpClient|Net\.Sockets|DownloadString|DownloadFile|Invoke-Expression|\biex\b|FromBase64String|EncodedCommand|Start-BitsTransfer'
# Expected output: nothing.
```

## License

[MIT](LICENSE). Provided "as is", without warranty. It changes system settings — keep a restore point (the app creates one by default).
