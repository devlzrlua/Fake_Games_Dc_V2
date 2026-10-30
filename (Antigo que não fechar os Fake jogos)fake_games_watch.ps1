
param(
    [Parameter(Mandatory=$true)]
    [string]$SessionDir
)

$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
'@

$session = [System.IO.Path]::GetFullPath($SessionDir).TrimEnd('\')
$pidFile = Join-Path $session "pids.txt"

# Descobre o processo CMD que iniciou este monitor
$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$parentPid = [int]$processInfo.ParentProcessId

# Confirma que o processo pai realmente e o CMD
try {
    $parentName = (Get-Process -Id $parentPid -ErrorAction Stop).ProcessName
    if ($parentName -ne "cmd") {
        $parentPid = 0
    }
}
catch {
    $parentPid = 0
}

function Get-TrackedIds {
    $ids = @()

    if (Test-Path $pidFile) {
        foreach ($line in (Get-Content -LiteralPath $pidFile)) {
            $id = 0

            if ([int]::TryParse($line, [ref]$id)) {
                try {
                    $p = Get-Process -Id $id -ErrorAction Stop
                    $path = $p.Path

                    # Confere se o executavel pertence a esta sessao
                    if ($path -and $path.StartsWith(
                        $session + '\',
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                        $ids += $id
                    }
                }
                catch {}
            }
        }
    }

    return $ids
}

function Stop-Tracked {
    foreach ($id in @(Get-TrackedIds)) {
        try {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Remove-SessionIfEmpty {
    Start-Sleep -Milliseconds 700

    if (@(Get-TrackedIds).Count -eq 0) {
        Remove-Item -LiteralPath $session -Recurse -Force
    }
}

function Confirm-Stop {
    return [System.Windows.Forms.MessageBox]::Show(
        "Deseja encerrar todos os jogos falsos desta execucao?",
        "Fake Games - Confirmacao",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

$wasDown = $false

while ($true) {

    $active = @(Get-TrackedIds)

    # Se todos os jogos terminaram naturalmente, encerra o monitor
    if ($active.Count -eq 0) {
        Remove-SessionIfEmpty
        break
    }

    # Verifica se o CMD foi fechado pelo X
    if ($parentPid -gt 0) {
        $parentAlive = $true

        try {
            Get-Process -Id $parentPid -ErrorAction Stop | Out-Null
        }
        catch {
            $parentAlive = $false
        }

        if (-not $parentAlive) {
            $answer = Confirm-Stop

            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                Stop-Tracked
                Remove-SessionIfEmpty
            }

            break
        }
    }

    # Detecta Ctrl+S globalmente enquanto esta sessao estiver ativa
    $ctrl = (([int][NativeKeys]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0)
    $sKey = (([int][NativeKeys]::GetAsyncKeyState(0x53) -band 0x8000) -ne 0)

    $down = $ctrl -and $sKey

    if ($down -and -not $wasDown) {

        $answer = Confirm-Stop

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {

            Stop-Tracked
            Remove-SessionIfEmpty

            # Fecha somente o CMD que iniciou este monitor
            if ($parentPid -gt 0) {
                Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
            }

            break
        }
    }

    $wasDown = $down

    Start-Sleep -Milliseconds 150
}
