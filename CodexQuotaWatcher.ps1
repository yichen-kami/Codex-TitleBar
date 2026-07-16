# Starts the titlebar companion with Codex and waits quietly between Codex sessions.
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\CodexQuotaTitlebarWatcher', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$companion = Join-Path $PSScriptRoot 'CodexQuotaTitlebar.ps1'
$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-CodexRunning {
    foreach ($process in Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        try {
            if ($process.Path -like '*\OpenAI.Codex_*\app\ChatGPT.exe') { return $true }
        } catch {}
    }
    return $false
}

try {
    while ($true) {
        try {
            while (-not (Test-CodexRunning)) { Start-Sleep -Seconds 2 }
            $child = Start-Process -FilePath $powerShell -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', $companion
            ) -WindowStyle Hidden -PassThru
            while (Test-CodexRunning) {
                if ($child.HasExited) {
                    $child = Start-Process -FilePath $powerShell -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', $companion
                    ) -WindowStyle Hidden -PassThru
                }
                Start-Sleep -Seconds 2
            }
            if (-not $child.HasExited) {
                $child.WaitForExit(5000) | Out-Null
                if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
            }
        } catch {
            # Transient process-query or launch failures must not stop monitoring.
            Start-Sleep -Seconds 5
        }
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
