#Requires -Version 7.4
param([string]$DataDirectory = (Join-Path $PSScriptRoot 'Data'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'Core.cs')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DesktopIdle {
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint size; public uint tick; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref Input input);
    public static uint Milliseconds() {
        var input = new Input { size = (uint)Marshal.SizeOf<Input>() };
        return GetLastInputInfo(ref input) ? unchecked((uint)Environment.TickCount - input.tick) : 0;
    }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()
[void][IO.Directory]::CreateDirectory($DataDirectory)
$script:vaultPath = Join-Path ([IO.Path]::GetFullPath($DataDirectory)) 'cuentas.vault'
try {
    $instanceLock = [IO.File]::Open((Join-Path $DataDirectory 'app.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    [void][Windows.Forms.MessageBox]::Show('La bóveda ya está abierta en otra ventana, o no se puede acceder a su carpeta.', 'Mi bóveda')
    exit 1
}
$script:session = $null
$script:editor = $null
$script:copied = $null
$script:copiedAt = [DateTime]::MinValue
$script:unlockedAt = [DateTime]::MinValue

function Show-Error([string]$message) {
    [void][Windows.Forms.MessageBox]::Show($message, 'Mi bóveda', 'OK', 'Error')
}
function Get-MasterPasswordValidationMessage([string]$password, [string]$confirmation) {
    if ($password.Length -lt 14) {
        return 'La contraseña maestra debe tener al menos 14 caracteres. Puedes usar una frase de varias palabras.'
    }
    if ($password -cne $confirmation) { return 'Las contraseñas no coinciden. Escríbelas exactamente igual.' }
    return ''
}
function Get-VaultAccessErrorMessage([Exception]$exception) {
    # PowerShell wraps exceptions from C# methods. Classify the underlying cause
    # without showing arbitrary exception text that could contain private data.
    while ($exception.InnerException) { $exception = $exception.InnerException }
    if ($exception -is [Security.Cryptography.CryptographicException]) {
        return 'La contraseña maestra es incorrecta o el archivo de la bóveda está dañado.'
    }
    if ($exception -is [UnauthorizedAccessException]) {
        return 'No tienes permiso para leer o guardar la bóveda en su carpeta.'
    }
    if ($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]) {
        return 'No se encuentra el archivo o la carpeta de la bóveda. Comprueba su ubicación.'
    }
    if ($exception -is [IO.InvalidDataException] -or $exception -is [FormatException] -or $exception -is [Text.Json.JsonException]) {
        return 'El archivo de la bóveda está dañado o tiene un formato no compatible. Puedes restaurar una copia cifrada.'
    }
    if ($exception -is [IO.IOException]) {
        return 'No se pudo acceder al archivo de la bóveda. Comprueba el espacio disponible y si otro programa lo está usando.'
    }
    return 'No se pudo abrir o crear la bóveda por un error inesperado. Cierra la aplicación y vuelve a intentarlo.'
}
function New-Label($parent, $text, $x, $y, $width = 360) {
    $c = [Windows.Forms.Label]::new()
    $c.Text = $text; $c.SetBounds($x, $y, $width, 24)
    $parent.Controls.Add($c)
    return $c
}
function New-Text($parent, $x, $y, $width = 360, [bool]$secret = $false) {
    $c = [Windows.Forms.TextBox]::new()
    $c.SetBounds($x, $y, $width, 29); $c.UseSystemPasswordChar = $secret
    $parent.Controls.Add($c)
    return $c
}
function New-Button($parent, $text, $x, $y, $width, $action) {
    $c = [Windows.Forms.Button]::new()
    $c.Text = $text; $c.SetBounds($x, $y, $width, 34)
    $c.Add_Click($action); $parent.Controls.Add($c)
    return $c
}
function New-Dialog($title, $width, $height) {
    $d = [Windows.Forms.Form]::new()
    $d.Text = $title; $d.ClientSize = [Drawing.Size]::new($width, $height)
    $d.Font = [Drawing.Font]::new('Segoe UI', 10)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    return $d
}
function Clear-Copied {
    if ($null -ne $script:copied) {
        try {
            if ([Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText() -ceq $script:copied) {
                [Windows.Forms.Clipboard]::Clear()
            }
        } catch { }
        $script:copied = $null
    }
}
function Refresh-Accounts {
    $script:list.Items.Clear()
    if ($null -eq $script:session) { return }
    $query = $script:search.Text.Trim()
    foreach ($entry in ($script:session.Entries | Sort-Object Service, Username)) {
        $haystack = "$($entry.Service) $($entry.Username) $($entry.Category) $($entry.Url)"
        if ($query -and $haystack.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $row = [Windows.Forms.ListViewItem]::new($entry.Service)
        [void]$row.SubItems.Add($entry.Username)
        [void]$row.SubItems.Add($entry.Category)
        [void]$row.SubItems.Add($entry.Url)
        $row.Tag = $entry
        [void]$script:list.Items.Add($row)
    }
    $script:status.Text = "$($script:session.Entries.Count) cuentas · Cambios guardados cifrados · Bloqueo tras 3 min sin usar el PC"
}
function Set-Locked {
    if ($script:editor) { $script:editor.DialogResult = 'Cancel'; $script:editor.Close() }
    Clear-Copied
    if ($script:session) { $script:session.Dispose(); $script:session = $null }
    $script:list.Items.Clear(); $script:search.Clear()
    foreach ($b in $script:accountButtons) { $b.Enabled = $false }
    $script:search.Enabled = $false
    $script:toggle.Text = 'Desbloquear'
    $script:restore.Enabled = $true
    $script:status.Text = 'Bóveda bloqueada · Pulsa Desbloquear para acceder a tus cuentas'
}
function Unlock-Vault {
    $create = -not [IO.File]::Exists($script:vaultPath)
    $d = New-Dialog $(if ($create) { 'Crea tu bóveda personal' } else { 'Desbloquea tu bóveda' }) 460 $(if ($create) { 340 } else { 230 })
    [void](New-Label $d 'Contraseña maestra' 24 22 410)
    $p = New-Text $d 24 50 410 $true
    $confirm = $null
    if ($create) {
        $lengthLabel = New-Label $d '0 / 14 caracteres mín.' 258 22 176
        $lengthLabel.ForeColor = [Drawing.Color]::Firebrick
        $p.Add_TextChanged({
            $lengthLabel.Text = "$($p.Text.Length) / 14 caracteres mín."
            $lengthLabel.ForeColor = if ($p.Text.Length -ge 14) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
        })
        [void](New-Label $d 'Repite la contraseña maestra' 24 95 410)
        $confirm = New-Text $d 24 123 410 $true
        $hint = New-Label $d 'Usa al menos 14 caracteres, por ejemplo varias palabras. Guarda esta frase: no hay recuperación si la olvidas.' 24 168 410
        $hint.Height = 64
    } else {
        [void](New-Label $d 'Tus cuentas se descifran únicamente al desbloquear.' 24 98 410)
    }
    $bottom = $d.ClientSize.Height - 62
    $ok = New-Button $d $(if ($create) { 'Crear bóveda' } else { 'Desbloquear' }) 24 $bottom 190 {
        try {
            if ($create) {
                $validationMessage = Get-MasterPasswordValidationMessage $p.Text $confirm.Text
                if ($validationMessage) { Show-Error $validationMessage; [void]$p.Focus(); return }
                $script:session = [MiBoveda.Vault]::Create($script:vaultPath, $p.Text)
            } else { $script:session = [MiBoveda.Vault]::Open($script:vaultPath, $p.Text) }
            $d.DialogResult = 'OK'; $d.Close()
        } catch { Show-Error (Get-VaultAccessErrorMessage $_.Exception) }
    }
    $cancel = New-Button $d 'Cancelar' 230 $bottom 204 { $d.Close() }
    $cancel.DialogResult = 'Cancel'; $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $d.Add_Shown({ $p.Focus() })
    try { [void]$d.ShowDialog($script:main) }
    finally { $p.Clear(); if ($confirm) { $confirm.Clear() }; $d.Dispose() }
    if ($script:session) {
        $script:unlockedAt = [DateTime]::UtcNow
        foreach ($b in $script:accountButtons) { $b.Enabled = $true }
        $script:search.Enabled = $true; $script:restore.Enabled = $false
        $script:toggle.Text = 'Bloquear'; Refresh-Accounts
    }
}
function Get-Selected {
    if ($script:list.SelectedItems.Count -eq 0) { return $null }
    return $script:list.SelectedItems[0].Tag
}
function Edit-Account([bool]$isNew) {
    if (-not $script:session) { return }
    $old = if ($isNew) { $null } else { Get-Selected }
    if (-not $isNew -and $null -eq $old) { return }
    $d = New-Dialog $(if ($isNew) { 'Añadir cuenta' } else { 'Editar cuenta' }) 560 630
    $script:editor = $d
    $fields = @{}
    $spec = @(@('Service','Servicio *'), @('Username','Correo o usuario'), @('Password','Contraseña'), @('Url','Enlace'), @('Category','Categoría'), @('Notes','Notas'))
    $y = 18
    foreach ($pair in $spec) {
        [void](New-Label $d $pair[1] 24 $y 510)
        $box = New-Text $d 24 ($y + 25) 510 ($pair[0] -eq 'Password')
        $box.MaxLength = 16000
        if ($old) { $box.Text = $old.($pair[0]) }
        elseif ($pair[0] -eq 'Category') { $box.Text = 'Personal' }
        $fields[$pair[0]] = $box
        $y += 72
        if ($pair[0] -eq 'Password') {
            $show = [Windows.Forms.CheckBox]::new(); $show.Text = 'Mostrar contraseña'; $show.SetBounds(24, $y, 220, 28)
            $show.Add_CheckedChanged({ $fields.Password.UseSystemPasswordChar = -not $show.Checked })
            $d.Controls.Add($show)
            [void](New-Button $d 'Generar (24 caracteres)' 280 $y 254 { $fields.Password.Text = [MiBoveda.Vault]::GeneratePassword(24) })
            $y += 42
        }
    }
    $fields.Notes.Multiline = $true; $fields.Notes.Height = 64; $fields.Notes.ScrollBars = 'Vertical'
    $save = New-Button $d 'Guardar cuenta' 24 570 245 {
        if (-not $fields.Service.Text.Trim()) { Show-Error 'Escribe el nombre del servicio.'; return }
        $entry = [MiBoveda.Entry]::new()
        if ($old) { $entry.Id = $old.Id }
        foreach ($name in $fields.Keys) { $entry.$name = $fields[$name].Text }
        $entry.Service = $entry.Service.Trim()
        $next = [Collections.Generic.List[MiBoveda.Entry]]::new()
        foreach ($existing in $script:session.Entries) { if ($existing.Id -ne $entry.Id) { $next.Add($existing) } }
        $next.Add($entry)
        try { $script:session.Save($next); $d.DialogResult = 'OK'; $d.Close() }
        catch { Show-Error 'No se pudo guardar. Tus cambios siguen en este formulario; revisa el espacio y los permisos.' }
    }
    $cancel = New-Button $d 'Cancelar' 289 570 245 { $d.Close() }
    $cancel.DialogResult = 'Cancel'; $d.CancelButton = $cancel
    try { [void]$d.ShowDialog($script:main) }
    finally { foreach ($box in $fields.Values) { $box.Clear() }; $script:editor = $null; $d.Dispose() }
    Refresh-Accounts
}
function Backup-Vault {
    $dialog = [Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter = 'Bóveda cifrada (*.vault)|*.vault'; $dialog.FileName = "MiBoveda-$([DateTime]::Now.ToString('yyyy-MM-dd-HHmmss')).vault"
    try {
        if ($dialog.ShowDialog($script:main) -eq 'OK') {
            if ([IO.Path]::GetFullPath($dialog.FileName) -ieq $script:vaultPath) { throw 'Elige otro archivo para la copia.' }
            [IO.File]::Copy($script:vaultPath, $dialog.FileName, $true)
            [void][Windows.Forms.MessageBox]::Show('Copia cifrada guardada. Necesitarás tu contraseña maestra para abrirla.', 'Mi bóveda')
        }
    } catch { Show-Error 'No se pudo crear la copia. Elige una ubicación distinta con permiso de escritura.' }
    finally { $dialog.Dispose() }
}
function Restore-Vault {
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'Bóveda cifrada (*.vault;*.previous)|*.vault;*.previous'
    try {
        if ($dialog.ShowDialog($script:main) -ne 'OK') { return }
        $source = $dialog.FileName
        $d = New-Dialog 'Restaurar copia cifrada' 460 250
        $label = New-Label $d 'Escribe la contraseña maestra de la copia. La copia sustituirá las cuentas actuales; se conservará el archivo anterior como cuentas.vault.previous.' 24 18 410
        $label.Height = 82
        $p = New-Text $d 24 108 410 $true
        $ok = New-Button $d 'Verificar y restaurar' 24 176 230 {
            $check = $null; $temp = $script:vaultPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                # Validate the exact copied bytes before replacing the active vault.
                [IO.File]::Copy($source, $temp, $false)
                $check = [MiBoveda.Vault]::Open($temp, $p.Text)
                $check.Dispose(); $check = $null
                if ([IO.File]::Exists($script:vaultPath)) { [IO.File]::Replace($temp, $script:vaultPath, $script:vaultPath + '.previous', $true) }
                else { [IO.File]::Move($temp, $script:vaultPath) }
                $d.DialogResult = 'OK'; $d.Close()
            } catch { Show-Error 'No se pudo restaurar. Comprueba la contraseña de la copia, el archivo y los permisos.' }
            finally { if ($check) { $check.Dispose() }; if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
        }
        $cancel = New-Button $d 'Cancelar' 270 176 164 { $d.Close() }
        $cancel.DialogResult = 'Cancel'; $d.AcceptButton = $ok; $d.CancelButton = $cancel
        try { [void]$d.ShowDialog($script:main) }
        finally { $p.Clear(); $d.Dispose() }
    } finally { $dialog.Dispose() }
}

$script:main = [Windows.Forms.Form]::new()
$script:main.Text = 'Mi bóveda · Gestor personal de contraseñas'
$script:main.ClientSize = [Drawing.Size]::new(1080, 650)
$script:main.MinimumSize = [Drawing.Size]::new(1096, 689)
$script:main.StartPosition = 'CenterScreen'
$script:main.Font = [Drawing.Font]::new('Segoe UI', 10)
$script:main.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
$title = New-Label $script:main 'Mi bóveda' 24 22 400
$title.Font = [Drawing.Font]::new('Segoe UI', 22, [Drawing.FontStyle]::Bold); $title.Height = 46
[void](New-Label $script:main 'Tus cuentas, en un solo lugar. Guardadas cifradas en este PC.' 26 75 850)
$script:toggle = New-Button $script:main 'Desbloquear' 888 27 164 {
    if ($script:session) { Set-Locked } else { Unlock-Vault }
}
[void](New-Label $script:main 'Buscar por servicio, usuario, categoría o enlace' 24 117 700)
$script:search = New-Text $script:main 24 147 1028
$script:search.Anchor = 'Top, Left, Right'; $script:search.Add_TextChanged({ Refresh-Accounts })
$add = New-Button $script:main '+ Añadir cuenta' 24 194 154 { Edit-Account $true }
$edit = New-Button $script:main 'Ver / editar' 188 194 138 { Edit-Account $false }
$copy = New-Button $script:main 'Copiar contraseña' 336 194 172 {
    $entry = Get-Selected
    if ($entry -and $script:session) {
        try {
            Clear-Copied
            if ($entry.Password.Length -eq 0) { return }
            [Windows.Forms.Clipboard]::SetText($entry.Password)
            $script:copied = $entry.Password; $script:copiedAt = [DateTime]::UtcNow
            $script:status.Text = 'Contraseña copiada · Se borrará del portapapeles en 20 segundos'
        } catch { Show-Error 'No se pudo acceder al portapapeles. Inténtalo de nuevo.' }
    }
}
$delete = New-Button $script:main 'Eliminar' 518 194 108 {
    $entry = Get-Selected
    if (-not $entry -or -not $script:session) { return }
    if ([Windows.Forms.MessageBox]::Show("¿Eliminar la cuenta de $($entry.Service)?", 'Eliminar cuenta', 'YesNo', 'Warning') -ne 'Yes') { return }
    $next = [Collections.Generic.List[MiBoveda.Entry]]::new()
    foreach ($e in $script:session.Entries) { if ($e.Id -ne $entry.Id) { $next.Add($e) } }
    try { $script:session.Save($next); Refresh-Accounts } catch { Show-Error 'No se pudo guardar la eliminación.' }
}
$backup = New-Button $script:main 'Crear copia' 636 194 138 { Backup-Vault }
$script:restore = New-Button $script:main 'Restaurar copia' 784 194 158 { Restore-Vault }
$script:accountButtons = @($add, $edit, $copy, $delete, $backup)
$script:list = [Windows.Forms.ListView]::new()
$script:list.SetBounds(24, 246, 1028, 328); $script:list.Anchor = 'Top, Bottom, Left, Right'
$script:list.View = 'Details'; $script:list.FullRowSelect = $true; $script:list.MultiSelect = $false
$script:list.HideSelection = $false
[void]$script:list.Columns.Add('Servicio', 230)
[void]$script:list.Columns.Add('Correo / usuario', 300)
[void]$script:list.Columns.Add('Categoría', 160)
[void]$script:list.Columns.Add('Enlace', 310)
$script:list.Add_DoubleClick({ Edit-Account $false })
$script:main.Controls.Add($script:list)
$script:status = New-Label $script:main '' 24 590 1028
$script:status.Height = 44; $script:status.Anchor = 'Bottom, Left, Right'
$timer = [Windows.Forms.Timer]::new(); $timer.Interval = 1000
$timer.Add_Tick({
    if ($script:copied -and ([DateTime]::UtcNow - $script:copiedAt).TotalSeconds -ge 20) { Clear-Copied }
    if ($script:session -and ([DateTime]::UtcNow - $script:unlockedAt).TotalSeconds -ge 180 -and [DesktopIdle]::Milliseconds() -ge 180000) { Set-Locked }
})
$script:main.Add_Resize({ if ($script:main.WindowState -eq 'Minimized' -and $script:session) { Set-Locked } })
$script:main.Add_Shown({ Unlock-Vault })
$script:main.Add_FormClosing({ Set-Locked })
try {
    Set-Locked; $timer.Start()
    [void]$script:main.ShowDialog()
} finally {
    $timer.Stop(); $timer.Dispose(); Set-Locked; $script:main.Dispose(); $instanceLock.Dispose()
}
