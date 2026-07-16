# Codex quota companion for Windows. Runs on Windows PowerShell 5.1 without an SDK.
$ErrorActionPreference = 'Stop'

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\CodexQuotaTitlebar', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeWindow {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr", SetLastError=true)] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    public const int GWL_EXSTYLE = -20;
    public const int GWLP_HWNDPARENT = -8;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public static readonly IntPtr HWND_TOP = IntPtr.Zero;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public static bool IsCodexWindow(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;
        uint processId;
        GetWindowThreadProcessId(hwnd, out processId);
        try {
            string path = Process.GetProcessById((int)processId).MainModule.FileName;
            return path.IndexOf("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0;
        } catch { return false; }
    }

    public static IntPtr FindCodexWindow() {
        IntPtr found = IntPtr.Zero;
        long largestArea = 0;
        EnumWindows((hwnd, state) => {
            if (IsWindowVisible(hwnd) && IsCodexWindow(hwnd)) {
                RECT rect;
                if (GetWindowRect(hwnd, out rect)) {
                    long width = Math.Max(0, rect.Right - rect.Left);
                    long height = Math.Max(0, rect.Bottom - rect.Top);
                    long area = width * height;
                    if (area > largestArea) { largestArea = area; found = hwnd; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Get-PropertyValue($Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Convert-ResetTime($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [ValueType] -or "$Value" -match '^\d+$') {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Value).ToLocalTime()
    }
    return [DateTimeOffset]::Parse("$Value").ToLocalTime()
}

function Read-ProxyUrl {
    $envPath = Join-Path $env:USERPROFILE '.codex\.env'
    if (-not (Test-Path -LiteralPath $envPath)) { return $null }
    $fallback = $null
    foreach ($line in Get-Content -LiteralPath $envPath) {
        if ($line -match '^\s*HTTPS_PROXY\s*=\s*(\S+)\s*$') { return $Matches[1] }
        if ($line -match '^\s*HTTP_PROXY\s*=\s*(\S+)\s*$') { $fallback = $Matches[1] }
    }
    return $fallback
}

function Get-QuotaSnapshot {
    $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { throw 'Sign in to Codex Desktop first' }
    $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $tokens = if ($auth.tokens) { $auth.tokens } else { $auth }
    $accessToken = Get-PropertyValue $tokens @('access_token', 'accessToken')
    $apiKey = Get-PropertyValue $auth @('OPENAI_API_KEY', 'openai_api_key', 'api_key')
    if (-not $apiKey) { $apiKey = Get-PropertyValue $tokens @('OPENAI_API_KEY', 'openai_api_key', 'api_key') }
    if (-not $apiKey) { $apiKey = $env:OPENAI_API_KEY }
    $authMode = Get-PropertyValue $auth @('auth_mode', 'authMode', 'mode')
    $explicitApiMode = "$authMode" -match '^(api|apikey|api_key)$'
    if ($explicitApiMode -or ($apiKey -and -not $accessToken)) {
        return [pscustomobject]@{ Mode = 'api'; Short = $null; Weekly = $null }
    }
    if (-not $accessToken) { throw 'Codex credentials are unavailable' }

    $headers = @{
        Authorization = "Bearer $accessToken"
        Accept = 'application/json'
        originator = 'Codex Desktop'
        'OAI-Product-Sku' = 'CODEX'
    }
    $accountId = Get-PropertyValue $tokens @('account_id', 'accountId')
    if ($accountId) { $headers['ChatGPT-Account-Id'] = $accountId }

    $request = @{
        Uri = 'https://chatgpt.com/backend-api/wham/usage'
        Method = 'GET'
        Headers = $headers
        TimeoutSec = 15
    }
    $proxy = Read-ProxyUrl
    if ($proxy) { $request.Proxy = $proxy }
    try {
        $usage = Invoke-RestMethod @request
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 401 -or $statusCode -eq 403) { throw 'Codex sign-in expired' }
        throw 'Quota service unavailable'
    } finally {
        $accessToken = $null
        $headers = $null
    }

    $rateLimit = Get-PropertyValue $usage @('rate_limit', 'rateLimit')
    if (-not $rateLimit) { $rateLimit = $usage }
    $primary = Get-PropertyValue $rateLimit @('primary_window', 'primaryWindow', 'short_window', 'shortWindow', 'five_hour_window', 'fiveHourWindow')
    $secondary = Get-PropertyValue $rateLimit @('secondary_window', 'secondaryWindow', 'weekly_window', 'weeklyWindow', 'week_window', 'weekWindow')

    function Parse-Window($window) {
        if (-not $window) { return $null }
        $remaining = Get-PropertyValue $window @('remaining_percent', 'remainingPercent', 'remaining_pct', 'remainingPct')
        if ($null -eq $remaining) {
            $used = Get-PropertyValue $window @('used_percent', 'usedPercent', 'used_pct', 'usedPct')
            if ($null -eq $used) { return $null }
            $remaining = 100.0 - [double]$used
        }
        $reset = Get-PropertyValue $window @('reset_at', 'resetAt', 'resets_at', 'resetsAt', 'reset_time', 'resetTime')
        $windowSeconds = Get-PropertyValue $window @('limit_window_seconds', 'limitWindowSeconds', 'window_seconds', 'windowSeconds', 'duration_seconds', 'durationSeconds')
        [pscustomobject]@{
            Percent = [math]::Max(0, [math]::Min(100, [math]::Round([double]$remaining)))
            Reset = Convert-ResetTime $reset
            WindowSeconds = if ($null -eq $windowSeconds) { 0 } else { [long]$windowSeconds }
        }
    }

    $primaryWindow = Parse-Window $primary
    $secondaryWindow = Parse-Window $secondary
    $shortWindow = $null
    $weeklyWindow = $null
    foreach ($candidate in @($primaryWindow, $secondaryWindow)) {
        if ($null -eq $candidate) { continue }
        if ($candidate.WindowSeconds -ge 500000) { $weeklyWindow = $candidate }
        elseif ($candidate.WindowSeconds -ge 17000 -and $candidate.WindowSeconds -le 19000) { $shortWindow = $candidate }
    }
    # Compatibility with older responses that omitted duration metadata.
    if ($null -eq $shortWindow -and $primaryWindow -and $primaryWindow.WindowSeconds -eq 0) { $shortWindow = $primaryWindow }
    if ($null -eq $weeklyWindow -and $secondaryWindow -and $secondaryWindow.WindowSeconds -eq 0) { $weeklyWindow = $secondaryWindow }
    if ($null -eq $shortWindow -and $null -eq $weeklyWindow) { throw 'Quota window format is unavailable' }

    [pscustomobject]@{ Mode = 'subscription'; Short = $shortWindow; Weekly = $weeklyWindow }
}

$quotaFetchScript = "`$ErrorActionPreference = 'Stop'`n"
$quotaFetchScript += (@(
    'Get-PropertyValue',
    'Convert-ResetTime',
    'Read-ProxyUrl',
    'Get-QuotaSnapshot'
) | ForEach-Object {
    "function $_ {`n$((Get-Item -LiteralPath "Function:\$_").Definition)`n}"
}) -join "`n"
$quotaFetchScript += "`nGet-QuotaSnapshot"

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="340" Height="32" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False"
        ShowActivated="False" Topmost="False" SnapsToDevicePixels="True">
  <Grid Margin="0">
    <Grid.Effect>
      <DropShadowEffect Color="#A0FFFFFF" BlurRadius="2" ShadowDepth="0" Opacity="0.9"/>
    </Grid.Effect>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <StackPanel x:Name="ShortGroup" Orientation="Horizontal" Width="136">
        <TextBlock Text="5h" Width="32" FontFamily="Segoe UI Variable Text" FontSize="14" VerticalAlignment="Center" Foreground="#B51F2937"/>
        <TextBlock x:Name="ShortPercent" Text="--%" Width="44" FontFamily="Segoe UI Variable Display" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#E610172A"/>
        <TextBlock x:Name="ShortText" Text="--:--" Width="60" FontFamily="Segoe UI Variable Text" FontSize="14" VerticalAlignment="Center" Foreground="#C910172A"/>
      </StackPanel>
      <TextBlock x:Name="Divider" Text="|" Width="16" FontFamily="Segoe UI Variable Text" FontSize="14" TextAlignment="Center" VerticalAlignment="Center" Foreground="#5510172A"/>
      <StackPanel x:Name="WeeklyGroup" Orientation="Horizontal" Width="188">
        <TextBlock Text="7d" Width="32" FontFamily="Segoe UI Variable Text" FontSize="14" VerticalAlignment="Center" Foreground="#B51F2937"/>
        <TextBlock x:Name="WeeklyPercent" Text="--%" Width="44" FontFamily="Segoe UI Variable Display" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Foreground="#E610172A"/>
        <TextBlock x:Name="WeeklyText" Text="--/-- --:--" Width="112" FontFamily="Segoe UI Variable Text" FontSize="14" VerticalAlignment="Center" Foreground="#C910172A"/>
      </StackPanel>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = [Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$shortGroup = $window.FindName('ShortGroup')
$divider = $window.FindName('Divider')
$weeklyGroup = $window.FindName('WeeklyGroup')
$shortPercent = $window.FindName('ShortPercent')
$shortText = $window.FindName('ShortText')
$weeklyPercent = $window.FindName('WeeklyPercent')
$weeklyText = $window.FindName('WeeklyText')
$codexHandle = [IntPtr]::Zero
$ownedCodexHandle = [IntPtr]::Zero
$overlayHandle = [IntPtr]::Zero
$lastRefresh = [DateTimeOffset]::MinValue
$refreshRequested = $true
$codexWasFound = $false
$codexMissingSince = $null
$acceptedShort = $null
$acceptedWeekly = $null
$pendingShort = $null
$pendingWeekly = $null
$displayWidth = 340
$codexRect = New-Object NativeWindow+RECT
$hasValidSnapshot = $false
$consecutiveRefreshFailures = 0
$quotaPowerShell = $null
$quotaAsync = $null

function Set-PercentState($textBlock, [double]$percent) {
    $textBlock.Text = '{0}%' -f $percent
    $color = if ($percent -le 15) { '#D13438' } elseif ($percent -le 35) { '#CA7602' } else { '#198754' }
    $textBlock.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Set-WindowLayout([bool]$HasShort, [bool]$HasWeekly) {
    if ($HasShort -and $HasWeekly) {
        $shortGroup.Visibility = 'Visible'
        $divider.Visibility = 'Visible'
        $weeklyGroup.Visibility = 'Visible'
        $script:displayWidth = 340
    } elseif ($HasWeekly) {
        $shortGroup.Visibility = 'Collapsed'
        $divider.Visibility = 'Collapsed'
        $weeklyGroup.Visibility = 'Visible'
        $script:displayWidth = 188
    } else {
        $shortGroup.Visibility = 'Visible'
        $divider.Visibility = 'Collapsed'
        $weeklyGroup.Visibility = 'Collapsed'
        $script:displayWidth = 136
    }
}

function Set-QuotaUnavailable {
    Set-WindowLayout $false $true
    $shortPercent.Text = '--'
    $shortText.Text = ''
    $weeklyPercent.Text = '--'
    $weeklyText.Text = ''
    $neutral = [Windows.Media.BrushConverter]::new().ConvertFromString('#8A6B7280')
    $shortPercent.Foreground = $neutral
    $weeklyPercent.Foreground = $neutral
    $window.ToolTip = $null
}

function Clear-QuotaHistory {
    $script:acceptedShort = $null
    $script:acceptedWeekly = $null
    $script:pendingShort = $null
    $script:pendingWeekly = $null
    $script:hasValidSnapshot = $false
}

function Get-StableWindow($Kind, $Candidate) {
    if ($null -eq $Candidate) { return $null }
    if ($Kind -eq 'short') {
        $accepted = $script:acceptedShort
        $pending = $script:pendingShort
    } else {
        $accepted = $script:acceptedWeekly
        $pending = $script:pendingWeekly
    }

    if ($null -eq $accepted) {
        if ($Kind -eq 'short') { $script:acceptedShort = $Candidate } else { $script:acceptedWeekly = $Candidate }
        return $Candidate
    }

    $candidateReset = if ($null -eq $Candidate.Reset) { 0 } else { $Candidate.Reset.ToUnixTimeSeconds() }
    $acceptedReset = if ($null -eq $accepted.Reset) { 0 } else { $accepted.Reset.ToUnixTimeSeconds() }
    $sameReset = $candidateReset -eq $acceptedReset
    $oldWindowHasReset = $null -ne $accepted.Reset -and [DateTimeOffset]::Now -ge $accepted.Reset.AddSeconds(-5)
    # Rolling weekly windows can move reset_at whenever usage changes.
    $normalDecrease = $Candidate.Percent -le $accepted.Percent
    $realNewWindow = -not $sameReset -and $oldWindowHasReset -and $Candidate.Reset -gt $accepted.Reset

    if ($normalDecrease -or $realNewWindow) {
        if ($Kind -eq 'short') {
            $script:acceptedShort = $Candidate
            $script:pendingShort = $null
        } else {
            $script:acceptedWeekly = $Candidate
            $script:pendingWeekly = $null
        }
        return $Candidate
    }

    # An upward jump before the known reset must be confirmed by two consecutive refreshes.
    $confirmed = $null -ne $pending -and
        $pending.Percent -eq $Candidate.Percent
    if ($confirmed) {
        if ($Kind -eq 'short') {
            $script:acceptedShort = $Candidate
            $script:pendingShort = $null
        } else {
            $script:acceptedWeekly = $Candidate
            $script:pendingWeekly = $null
        }
        return $Candidate
    }

    if ($Kind -eq 'short') { $script:pendingShort = $Candidate } else { $script:pendingWeekly = $Candidate }
    return $accepted
}

function Apply-QuotaSnapshot($snapshot) {
    if ($snapshot.Mode -eq 'api') {
        Set-QuotaUnavailable
        Clear-QuotaHistory
        $script:consecutiveRefreshFailures = 0
        return
    }
    $stableShort = Get-StableWindow 'short' $snapshot.Short
    $stableWeekly = Get-StableWindow 'weekly' $snapshot.Weekly
    Set-WindowLayout ($null -ne $stableShort) ($null -ne $stableWeekly)
    if ($stableShort) {
        $shortText.Text = if ($stableShort.Reset) { $stableShort.Reset.ToString('HH:mm') } else { '--:--' }
        Set-PercentState $shortPercent $stableShort.Percent
    }
    if ($stableWeekly) {
        $weeklyText.Text = if ($stableWeekly.Reset) { $stableWeekly.Reset.ToString('M/d HH:mm') } else { '--/-- --:--' }
        Set-PercentState $weeklyPercent $stableWeekly.Percent
    }
    if ($stableShort -and $stableWeekly -and $stableShort.Reset -and $stableWeekly.Reset) {
        $window.ToolTip = '5h reset: {0}`n7d reset: {1}' -f $stableShort.Reset.ToString('yyyy-MM-dd HH:mm'), $stableWeekly.Reset.ToString('yyyy-MM-dd HH:mm')
    } elseif ($stableWeekly -and $stableWeekly.Reset) {
        $window.ToolTip = '7d reset: {0}' -f $stableWeekly.Reset.ToString('yyyy-MM-dd HH:mm')
    } elseif ($stableShort -and $stableShort.Reset) {
        $window.ToolTip = '5h reset: {0}' -f $stableShort.Reset.ToString('yyyy-MM-dd HH:mm')
    }
    $script:hasValidSnapshot = $true
    $script:consecutiveRefreshFailures = 0
}

function Apply-QuotaFailure([string]$failureMessage) {
    $script:consecutiveRefreshFailures++
    $credentialFailure = $failureMessage -in @(
        'Sign in to Codex Desktop first',
        'Codex credentials are unavailable',
        'Codex sign-in expired'
    )
    $now = [DateTimeOffset]::Now
    $knownWindowStillValid =
        ($acceptedShort -and ($null -eq $acceptedShort.Reset -or $acceptedShort.Reset -gt $now)) -or
        ($acceptedWeekly -and ($null -eq $acceptedWeekly.Reset -or $acceptedWeekly.Reset -gt $now))
    # Network and service failures keep the last good value until its known reset time.
    if ($credentialFailure -or -not $hasValidSnapshot -or -not $knownWindowStillValid) {
        Set-QuotaUnavailable
        Clear-QuotaHistory
    }
}

function Start-QuotaRefresh {
    if ($null -ne $quotaAsync) { return }
    $script:quotaPowerShell = [PowerShell]::Create()
    [void]$quotaPowerShell.AddScript($quotaFetchScript)
    try {
        $script:quotaAsync = $quotaPowerShell.BeginInvoke()
    } catch {
        $quotaPowerShell.Dispose()
        $script:quotaPowerShell = $null
        Apply-QuotaFailure $_.Exception.Message
        $script:lastRefresh = [DateTimeOffset]::Now
        $script:refreshRequested = $false
    }
}

function Complete-QuotaRefresh {
    if ($null -eq $quotaAsync -or -not $quotaAsync.IsCompleted) { return }
    try {
        $results = @($quotaPowerShell.EndInvoke($quotaAsync))
        $snapshot = $results | Select-Object -Last 1
        if ($null -eq $snapshot) { throw 'Quota service returned no data' }
        Apply-QuotaSnapshot $snapshot
    } catch {
        Apply-QuotaFailure $_.Exception.Message
    } finally {
        $quotaPowerShell.Dispose()
        $script:quotaPowerShell = $null
        $script:quotaAsync = $null
        $script:lastRefresh = [DateTimeOffset]::Now
        $script:refreshRequested = $false
    }
}

function Update-QuotaDisplay {
    Start-QuotaRefresh
}

function Stop-QuotaRefresh {
    if ($null -ne $quotaPowerShell) {
        try { $quotaPowerShell.Stop() } catch {}
        $quotaPowerShell.Dispose()
    }
    $script:quotaPowerShell = $null
    $script:quotaAsync = $null
}

$window.Add_SourceInitialized({
    $script:overlayHandle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
    $style = [NativeWindow]::GetWindowLong($overlayHandle, [NativeWindow]::GWL_EXSTYLE)
    [void][NativeWindow]::SetWindowLong($overlayHandle, [NativeWindow]::GWL_EXSTYLE,
        $style -bor [NativeWindow]::WS_EX_TOOLWINDOW -bor [NativeWindow]::WS_EX_NOACTIVATE -bor [NativeWindow]::WS_EX_TRANSPARENT)
})

$tray = [Windows.Forms.NotifyIcon]::new()
$tray.Icon = [Drawing.SystemIcons]::Information
$tray.Text = 'Codex Quota Titlebar'
$tray.Visible = $true
$menu = [Windows.Forms.ContextMenuStrip]::new()
$refreshItem = $menu.Items.Add('Refresh now')
$exitItem = $menu.Items.Add('Exit')
$refreshItem.Add_Click({ $script:refreshRequested = $true })
$exitItem.Add_Click({ $tray.Visible = $false; $window.Close() })
$tray.ContextMenuStrip = $menu

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
    Complete-QuotaRefresh
    if ($codexHandle -eq [IntPtr]::Zero -or -not [NativeWindow]::IsWindow($codexHandle)) {
        $script:codexHandle = [NativeWindow]::FindCodexWindow()
    }
    if ($codexHandle -ne [IntPtr]::Zero) {
        $script:codexWasFound = $true
        $script:codexMissingSince = $null
    } elseif ($codexWasFound) {
        if ($null -eq $codexMissingSince) { $script:codexMissingSince = [DateTimeOffset]::Now }
        if (([DateTimeOffset]::Now - $codexMissingSince).TotalSeconds -ge 2) {
            $window.Close()
            return
        }
    }
    $show = $codexHandle -ne [IntPtr]::Zero -and [NativeWindow]::IsWindowVisible($codexHandle) -and -not [NativeWindow]::IsIconic($codexHandle)
    if (-not $show) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }

    if ([NativeWindow]::GetWindowRect($codexHandle, [ref]$codexRect)) {
        if ($ownedCodexHandle -ne $codexHandle) {
            [void][NativeWindow]::SetWindowLongPtr($overlayHandle, [NativeWindow]::GWLP_HWNDPARENT, $codexHandle)
            $script:ownedCodexHandle = $codexHandle
        }
        # Leave the standard minimize/maximize/close caption buttons untouched.
        $width = $displayWidth; $height = 32
        $x = $codexRect.Right - 144 - $width - 8
        $y = $codexRect.Top + 7
        [void][NativeWindow]::SetWindowPos($overlayHandle, [NativeWindow]::HWND_TOP, $x, $y, $width, $height,
            [NativeWindow]::SWP_NOACTIVATE -bor [NativeWindow]::SWP_SHOWWINDOW)
        if (-not $window.IsVisible) { $window.Show() }
    }

    $refreshIntervalSeconds = if ($consecutiveRefreshFailures -gt 0) { 10 } else { 30 }
    if ($refreshRequested -or ([DateTimeOffset]::Now - $lastRefresh).TotalSeconds -ge $refreshIntervalSeconds) {
        Update-QuotaDisplay
    }
})

$window.Add_Closed({
    $timer.Stop()
    Stop-QuotaRefresh
    $tray.Visible = $false
    $tray.Dispose()
    $menu.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    [Windows.Threading.Dispatcher]::ExitAllFrames()
})

$timer.Start()
$window.Show()
$window.Hide()
[void][Windows.Threading.Dispatcher]::Run()
