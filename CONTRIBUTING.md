# Contribuir

¡Gracias por querer mejorar Z. Optimizer! Para que siga siendo un proyecto sin humo, cualquier cambio debe cumplir estas reglas:

## Reglas para ajustes nuevos

- **Documentado:** explica qué hace, en qué builds de Windows 11 funciona y enlaza la fuente (documentación de Microsoft, mediciones, etc.).
- **Reversible:** usa `Set-Reg`, `Set-ServiceStart` o `Disable-ZSchedTask` para que quede en el journal, o añade su bloque `Revert` si es un `.reg`.
- **Honesto:** si el efecto es pequeño o discutido, la descripción lo dice. Sin "+50 FPS".
- **Seguro:** nada que desactive Defender, SmartScreen, UAC, Windows Update, el firewall o las mitigaciones de CPU.
- **Sin red ni binarios:** no se aceptan descargas, `Invoke-Expression`, código ofuscado ni ejecutables.

## Cómo probar

1. Crea un punto de restauración (o usa una máquina virtual).
2. Ejecuta con **Solo simular** y revisa la consola.
3. Aplica, reinicia, comprueba y luego **deshaz** desde Restaurar: el sistema debe volver al estado inicial.

## Licencia

Al enviar una contribución aceptas que se publique bajo la licencia del proyecto, [GPL-3.0-or-later](LICENSE).

## Estilo

- PowerShell 5.1 compatible, archivo en UTF-8 **con BOM** y finales de línea CRLF.
- Textos de la interfaz en español, en el mismo tono que los existentes.
