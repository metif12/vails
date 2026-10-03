# capture.ps1 - screenshot helper for the Windows E2E proofs.
#
# The proofs in tests/e2e_windows/README.md need a picture of the window; this
# makes taking one repeatable instead of a manual snip.
#
#   .\capture.ps1 -Out shot.png -WindowTitle "Vails Services Demo"   # preferred
#   .\capture.ps1 -Out shot.png                                     # whole screen
#
# PREFER -WindowTitle, AND THE REASON IS PRIVACY, NOT CONVENIENCE.
#
# Every screenshot in this directory was removed on 2026-09-29 and purged from
# the repository's history. A full-screen capture frames the app window against
# whatever else is on the desktop, and what was on it was: the taskbar with the
# user's installed apps, an open terminal, a file manager, and the local
# username in a path. Those images are not a proof problem - the status lines in
# the README are the machine-checkable part - but they are a privacy problem,
# and a screenshot that leaks a desktop survives in every clone forever.
#
# -WindowTitle captures only the app window's rectangle, after raising it, so
# the desktop cannot end up in the frame. The whole-screen mode is still here
# for the one case that needs it (a tray balloon is drawn by the shell and is
# not part of any window), but it will include the desktop: close your other
# windows, or expect it to be a picture of your desktop as well as of the app.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$WindowTitle = "",
    [int]$DelayMs = 0
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }

if ($WindowTitle -ne "") {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public class Win {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
    # Raise it, and keep raising until it really is in front: a window shot of
    # a covered window shows whatever is on top of it, which is how a proof
    # screenshot ends up proving nothing (a busy desktop makes this a race).
    $target = $null
    for ($try = 0; $try -lt 10; $try++) {
        $target = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" } |
            Select-Object -First 1
        if (-not $target) { break }
        [void][Win]::ShowWindow($target.MainWindowHandle, 9)   # SW_RESTORE
        [void][Win]::SetForegroundWindow($target.MainWindowHandle)
        Start-Sleep -Milliseconds 300
        $fg = [Win]::GetForegroundWindow()
        if ($fg -eq $target.MainWindowHandle) { break }
    }
    if ($target) {
        $rect = New-Object RECT
        [void][Win]::GetWindowRect($target.MainWindowHandle, [ref]$rect)
        $x = $rect.Left; $y = $rect.Top
        $w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
    } else {
        Write-Warning "no window titled like '$WindowTitle'; capturing the whole screen"
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $x = $b.X; $y = $b.Y; $w = $b.Width; $h = $b.Height
    }
} else {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = $b.X; $y = $b.Y; $w = $b.Width; $h = $b.Height
}

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
$g.Dispose()
$dir = Split-Path -Parent $Out
if ($dir -ne "" -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $Out ($w x $h)"
