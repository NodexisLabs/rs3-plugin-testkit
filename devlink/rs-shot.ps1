# Captures only the RuneScape client's area of the screen to a PNG. It never
# focuses, moves or hides any window. The client draws with OpenGL, which
# PrintWindow cannot read, so this copies the on-screen pixels inside the
# client rectangle, and refuses to capture when another window covers any
# part of it (so no other app's content can end up in the image).
#   powershell -File rs-shot.ps1 [-Out path.png] [-ConsoleOnly] [-Region x,y,w,h]
# -Region captures only that rectangle of the client (client pixels), so a
# window covering some other part of the game doesn't block it.
param(
    [string]$Out = (Join-Path $PSScriptRoot "shots\rs-$(Get-Date -Format 'HHmmss').png"),
    [switch]$ConsoleOnly,  # keep only the top strip where the dev console draws
    [string]$Region        # "x,y,width,height" inside the client area
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RsShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][RsShot]::SetProcessDPIAware()   # physical pixels, matching CopyFromScreen

$proc = Get-Process rs2client -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "RuneScape client (rs2client) window not found" }
$hwnd = $proc.MainWindowHandle
if ([RsShot]::IsIconic($hwnd)) { throw "RuneScape client is minimised; nothing to capture" }

$rect = New-Object RsShot+RECT
[void][RsShot]::GetClientRect($hwnd, [ref]$rect)
$origin = New-Object RsShot+POINT
[void][RsShot]::ClientToScreen($hwnd, [ref]$origin)
$w = $rect.Right; $h = $rect.Bottom
if ($ConsoleOnly) { $h = [int]($h * 0.25) }
if ($Region) {
    $rg = [int[]]($Region -split ',')
    if ($rg.Count -ne 4) { throw "-Region needs x,y,width,height" }
    $origin.X += $rg[0]; $origin.Y += $rg[1]
    $w = [math]::Min($rg[2], $rect.Right - $rg[0]); $h = [math]::Min($rg[3], $rect.Bottom - $rg[1])
}

# Sample a grid of points: each must belong to the RuneScape window.
foreach ($fx in 0.02, 0.25, 0.5, 0.75, 0.98) {
    foreach ($fy in 0.02, 0.25, 0.5, 0.75, 0.98) {
        $p = New-Object RsShot+POINT
        $p.X = $origin.X + [int]($w * $fx); $p.Y = $origin.Y + [int]($h * $fy)
        $top = [RsShot]::GetAncestor([RsShot]::WindowFromPoint($p), 2)   # 2 = GA_ROOT
        if ($top -ne $hwnd) { throw "another window covers part of the RuneScape client; not capturing" }
    }
}

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($origin.X, $origin.Y, 0, 0, (New-Object System.Drawing.Size $w, $h))
$g.Dispose()
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output $Out
