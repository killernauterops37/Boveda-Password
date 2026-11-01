#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'Core.cs')
$dir = Join-Path $PSScriptRoot ('test-output/' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$path = Join-Path $dir 'test.vault'
$pass = 'Frase de prueba ficticia 2026!'
$script:checks = 0
function Assert($condition, $message) {
    if (-not $condition) { throw "FALLO: $message" }
    $script:checks++; Write-Output "OK: $message"
}
function Reject($action, $message) {
    $failed = $false
    try { & $action } catch { $failed = $true }
    Assert $failed $message
}
$vault = $null; $opened = $null
try {
    Reject { [MiBoveda.Vault]::Create($path, 'corta') } 'Rechaza contraseña maestra corta'
    $vault = [MiBoveda.Vault]::Create($path, $pass)
    Assert ($vault.Entries.Count -eq 0) 'Crea bóveda vacía'
    Reject { [MiBoveda.Vault]::Create($path, $pass) } 'No sobrescribe una bóveda al crearla'
    $entry = [MiBoveda.Entry]::new()
    $entry.Service = 'Servicio ficticio ñ 漢字'; $entry.Username = 'prueba@example.invalid'
    $entry.Password = 'SoloParaPruebas!987'; $entry.Notes = "Nota con salto`ny tildes: áéí"
    $entries = [Collections.Generic.List[MiBoveda.Entry]]::new(); $entries.Add($entry)
    $vault.Save($entries)
    $raw = [IO.File]::ReadAllText($path)
    Assert (-not $raw.Contains($entry.Password) -and -not $raw.Contains($entry.Username) -and -not $raw.Contains('Servicio')) 'No guarda cuentas ni contraseñas en texto plano'
    $opened = [MiBoveda.Vault]::Open($path, $pass)
    Assert ($opened.Entries.Count -eq 1 -and $opened.Entries[0].Password -ceq $entry.Password -and $opened.Entries[0].Notes -ceq $entry.Notes -and $opened.Entries[0].Service -ceq $entry.Service) 'Recupera todos los datos y caracteres Unicode'
    $opened.Dispose(); $opened = $null
    Reject { [MiBoveda.Vault]::Open($path, 'Frase incorrecta') } 'Rechaza contraseña incorrecta'
    $firstNonce = ($raw | ConvertFrom-Json).Nonce
    $vault.Save($entries)
    Assert (([IO.File]::ReadAllText($path) | ConvertFrom-Json).Nonce -cne $firstNonce) 'Cada guardado utiliza un nonce nuevo'
    $opened = [MiBoveda.Vault]::Open($path + '.previous', $pass)
    Assert ($opened.Entries.Count -eq 1) 'Conserva una versión anterior cifrada y legible'
    $opened.Dispose(); $opened = $null
    $copy = Join-Path $dir 'backup.vault'; [IO.File]::Copy($path, $copy)
    $opened = [MiBoveda.Vault]::Open($copy, $pass)
    Assert ($opened.Entries[0].Username -ceq $entry.Username) 'La copia cifrada se puede abrir de forma independiente'
    $opened.Dispose(); $opened = $null
    $envelope = $raw | ConvertFrom-Json
    $cipher = [Convert]::FromBase64String($envelope.Ciphertext); $cipher[0] = $cipher[0] -bxor 1
    $envelope.Ciphertext = [Convert]::ToBase64String($cipher)
    $bad = Join-Path $dir 'altered.vault'; [IO.File]::WriteAllText($bad, ($envelope | ConvertTo-Json))
    Reject { [MiBoveda.Vault]::Open($bad, $pass) } 'Rechaza contenido cifrado alterado'
    $envelope.Iterations = 1; [IO.File]::WriteAllText($bad, ($envelope | ConvertTo-Json))
    Reject { [MiBoveda.Vault]::Open($bad, $pass) } 'Rechaza parámetros criptográficos alterados'
    [IO.File]::WriteAllText($bad, '{"Version":')
    Reject { [MiBoveda.Vault]::Open($bad, $pass) } 'Rechaza archivos truncados'
    $empty = [Collections.Generic.List[MiBoveda.Entry]]::new(); $vault.Save($empty)
    $opened = [MiBoveda.Vault]::Open($path, $pass)
    Assert ($opened.Entries.Count -eq 0) 'Persiste la eliminación de cuentas'
    $opened.Dispose(); $opened = $null
    $vault.Dispose()
    Reject { $vault.Save($empty) } 'No permite guardar con una sesión bloqueada'
    $generated = [MiBoveda.Vault]::GeneratePassword(24)
    Assert ($generated.Length -eq 24 -and $generated -cne [MiBoveda.Vault]::GeneratePassword(24)) 'Genera contraseñas aleatorias de la longitud solicitada'
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'MiBoveda.ps1'), [ref]$null, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'El script de la interfaz no contiene errores de sintaxis'
    # Load only pure validation functions from the UI script; do not start or
    # automate the password manager, or read its personal Data directory.
    $uiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'MiBoveda.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Get-MasterPasswordValidationMessage', 'Get-VaultAccessErrorMessage')) {
        $definition = $uiAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
        . ([ScriptBlock]::Create($definition.Extent.Text))
    }
    $short = 'a' * 13
    Assert ((Get-MasterPasswordValidationMessage $short $short) -like '*14 caracteres*') 'La interfaz explica el mínimo cuando se introducen 13 caracteres'
    $valid = 'a' * 14
    Assert ((Get-MasterPasswordValidationMessage $valid $valid) -eq '') 'La interfaz acepta exactamente 14 caracteres coincidentes'
    Assert ((Get-MasterPasswordValidationMessage $valid ('A' * 14)) -like '*no coinciden*') 'La confirmación distingue mayúsculas de minúsculas'
    Assert ((Get-MasterPasswordValidationMessage '' '') -like '*14 caracteres*') 'La interfaz explica por qué no acepta una contraseña vacía'
    $wrapped = [Exception]::new('envoltorio', [Security.Cryptography.CryptographicException]::new('detalle privado'))
    Assert ((Get-VaultAccessErrorMessage $wrapped) -like '*incorrecta*') 'Identifica errores de descifrado dentro del envoltorio de PowerShell'
    Assert ((Get-VaultAccessErrorMessage ([UnauthorizedAccessException]::new('detalle privado'))) -like '*permiso*') 'Distingue errores de permisos sin mostrar detalles privados'
    Assert ((Get-VaultAccessErrorMessage ([IO.InvalidDataException]::new('detalle privado'))) -like '*formato*') 'Distingue archivos dañados de errores de permisos'
    Write-Output "$script:checks comprobaciones correctas. Archivos ficticios: $dir"
} finally {
    if ($opened) { $opened.Dispose() }
    if ($vault) { $vault.Dispose() }
}
