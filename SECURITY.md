# Seguridad

Z. Optimizer nace para ser lo contrario de los "optimizadores" que esconden malware. Estas son sus garantías y cómo comprobarlas.

## Garantías

1. **Un único archivo de código fuente** (`Z-Optimizer.ps1`) más un lanzador `.bat` de 5 líneas. Nunca se publicarán `.exe` ni binarios compilados en este repositorio.
2. **Sin red.** El script no abre conexiones, no descarga nada y no envía datos.
3. **Sin código dinámico.** Nada de `Invoke-Expression`, Base64 ni comandos codificados.
4. **No debilita la seguridad.** No desactiva Defender, SmartScreen, UAC, Windows Update, el firewall ni las mitigaciones de CPU.
5. **Reversible.** Los cambios se registran en `%ProgramData%\ZOptimizer\journals\` antes de aplicarse.

## Cómo verificar una descarga

- Descarga solo desde este repositorio oficial. **Cualquier copia que venga como `.exe`, `.zip` con contraseña o desde otra web no es oficial.**
- Compara el hash SHA256 con el publicado en la Release:

  ```powershell
  Get-FileHash .\Z-Optimizer.ps1 -Algorithm SHA256
  ```

- Comprueba que no hay llamadas de red ni código dinámico (comando en el [README](README.md#audítalo-tú-mismo)).

## Informar de un problema

Si encuentras una vulnerabilidad, un ajuste peligroso o una copia maliciosa que se hace pasar por este proyecto, abre un *issue* o, si es sensible, usa **Security → Report a vulnerability** (aviso privado) en GitHub.
