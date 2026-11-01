# Mi bóveda

Primera versión de un gestor personal de contraseñas para Windows. Funciona sin conexión y no utiliza servidores ni cuentas externas.

## Abrir

1. Haz doble clic en **Iniciar.cmd** dentro de esta carpeta.
2. Crea una contraseña maestra de al menos 14 caracteres. Una frase larga de varias palabras es más fácil de recordar. Guárdala en un lugar seguro: no hay restablecimiento ni recuperación sin ella.
3. Pulsa **Añadir cuenta**. Puedes guardar servicio, correo o usuario, contraseña, enlace, categoría y notas.
4. Selecciona una fila y usa **Ver / editar** o **Copiar contraseña**. Un doble clic también abre la cuenta.

Requiere Windows y PowerShell 7.4 o posterior (ya disponible en el equipo donde se creó). No necesita Python ni instalar paquetes. Si Windows impide ejecutar scripts por una política de tu organización, consulta con su administrador; el iniciador no cambia esa política.

## Protección y copias

- Todos los campos se guardan cifrados en `Data/cuentas.vault`. La contraseña maestra no se escribe en el archivo.
- AES-256-GCM de .NET con nonce aleatorio nuevo en cada guardado; PBKDF2-HMAC-SHA256 con 600.000 iteraciones y salt aleatorio de 32 bytes para derivar la clave. [Documentación de AES-GCM de Microsoft](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.aesgcm.encrypt?view=net-10.0).
- Los cambios se guardan al pulsar **Guardar cuenta**. Un archivo temporal cifrado se reemplaza de forma atómica; `Data/cuentas.vault.previous` conserva la versión anterior. Esta versión puede contener cuentas que hayas eliminado recientemente.
- **Crear copia** exporta una copia cifrada. Guárdala en otra unidad para protegerte frente a la pérdida del PC. Una copia en el mismo disco no cubre ese riesgo.
- Para restaurar: bloquea la bóveda, pulsa **Restaurar copia**, elige el archivo e introduce la contraseña maestra de esa copia. Restaurar sustituye las cuentas actuales y conserva el archivo anterior en `.previous`; no combina cuentas. También admite el archivo `.previous` como origen.
- Se bloquea al minimizar y tras 3 minutos sin actividad en el PC. El bloqueo por inactividad descarta un formulario de edición abierto sin guardar. Guarda tus cambios antes de alejarte.
- El portapapeles se limpia al bloquear o después de 20 segundos si todavía contiene la contraseña copiada. El historial de Windows, la sincronización del portapapeles y otras aplicaciones pueden conservar copias; evita esas funciones al copiar contraseñas.
- Solo una ventana puede acceder a la carpeta de la bóveda a la vez. No sincronices ni edites el archivo con otra aplicación mientras esté abierto.

## Alcance de esta versión

Es una primera implementación personal, sin auditoría independiente de seguridad. Se han probado el cifrado, el guardado, el rechazo de contraseñas incorrectas y archivos alterados, y la apertura de copias con datos ficticios. La interfaz requiere revisión manual: las herramientas de control del equipo no permiten automatizar gestores de contraseñas.

Una bóveda desbloqueada conserva los datos en la memoria del proceso. Las claves y buffers temporales se borran en la medida posible al bloquear, pero .NET y PowerShell utilizan cadenas administradas que no permiten garantizar su eliminación de la memoria. El cifrado del archivo no protege contra programas maliciosos que controlen el equipo, capturas de pantalla o un PC ya desbloqueado. No hay integración con el navegador, cambio de contraseña maestra ni versión móvil todavía.

Para mover la aplicación, conserva toda la carpeta y especialmente `Data`. Mover solo el iniciador no mueve tus cuentas.

## Verificación del código

Desde PowerShell 7, en esta carpeta:

```powershell
pwsh -NoProfile -File .\Test-Core.ps1
```

Las pruebas solo usan datos ficticios en una subcarpeta nueva de `test-output`; nunca abren la bóveda personal.
