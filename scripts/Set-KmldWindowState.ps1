#requires -Version 7.0
<#
.SYNOPSIS
  Minimizes or restores the main window of the identity-verified, mission-owned game process (window-manager call
  ShowWindow; no keyboard/mouse input is synthesized). Used for the post-idle "minimized" condition of W01.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][long]$ExpectedCreationFileTimeUtc,
    [ValidateSet('Minimize', 'Restore')][string]$State = 'Minimize'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }
if (-not ('KmldWin.WindowState' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace KmldWin { public static class WindowState {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
} }
'@
}
$b = [Kmld.BoundProcess]::Bind($ProcessId, $ExpectedCreationFileTimeUtc, $false)
try {
    $p = [Diagnostics.Process]::GetProcessById($ProcessId)
    if ($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $ExpectedCreationFileTimeUtc) { throw 'identity mismatch' }
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { throw 'no main window handle' }
    $cmd = if ($State -eq 'Minimize') { 7 } else { 9 }   # SW_SHOWMINNOACTIVE / SW_RESTORE
    [void][KmldWin.WindowState]::ShowWindow($h, $cmd)
    Start-Sleep -Milliseconds 500
    [ordered]@{ utc = (Get-Date).ToUniversalTime().ToString('o'); pid = $ProcessId; state = $State; iconicAfter = [KmldWin.WindowState]::IsIconic($h) } | ConvertTo-Json -Compress
} finally { $b.Dispose() }
