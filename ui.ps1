param([string]$Payload)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Emit($obj) {
  [Console]::Out.Write(($obj | ConvertTo-Json -Depth 8 -Compress))
  exit 0
}
function Fail($msg) {
  [Console]::Out.Write((@{ ok = $false; error = [string]$msg } | ConvertTo-Json -Depth 8 -Compress))
  exit 0
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class CuaNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, int dwData, IntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);

  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@
try { Add-Type -TypeDefinition $code -ErrorAction Stop } catch { Fail "Add-Type failed: $($_.Exception.Message)" }

[void][CuaNative]::SetProcessDPIAware()

$MOUSE = @{ MOVE = 0x0001; LEFTDOWN = 0x0002; LEFTUP = 0x0004; RIGHTDOWN = 0x0008; RIGHTUP = 0x0010; MIDDLEDOWN = 0x0020; MIDDLEUP = 0x0040; WHEEL = 0x0800 }
$KEYUP = 0x0002
$EXT = 0x0001

$VK = @{
  "enter" = 0x0D; "return" = 0x0D; "tab" = 0x09; "esc" = 0x1B; "escape" = 0x1B; "space" = 0x20;
  "backspace" = 0x08; "back" = 0x08; "delete" = 0x2E; "del" = 0x2E; "insert" = 0x2D; "ins" = 0x2D;
  "home" = 0x24; "end" = 0x23; "pageup" = 0x21; "pagedown" = 0x22; "pgup" = 0x21; "pgdn" = 0x22;
  "up" = 0x26; "down" = 0x28; "left" = 0x25; "right" = 0x27;
  "ctrl" = 0x11; "control" = 0x11; "shift" = 0x10; "alt" = 0x12; "win" = 0x5B; "lwin" = 0x5B; "menu" = 0x5D;
  "capslock" = 0x14; "printscreen" = 0x2C;
  ";" = 0xBA; "=" = 0xBB; "," = 0xBC; "-" = 0xBD; "." = 0xBE; "/" = 0xBF; "``" = 0xC0;
  "[" = 0xDB; "\" = 0xDC; "]" = 0xDD; "'" = 0xDE; "+" = 0xBB; ":" = 0xBA; "*" = 0x6A; "?" = 0xBF;
}
for ($i = 1; $i -le 12; $i++) { $VK["f$i"] = 0x6F + $i }

function Get-Vk([string]$name) {
  $n = $name.Trim().ToLower()
  if ($n.Length -eq 1) {
    $c = [int][char]$n
    if ($c -ge 97 -and $c -le 122) { return $c - 32 }
    if ($c -ge 48 -and $c -le 57) { return $c }
  }
  if ($VK.ContainsKey($n)) { return $VK[$n] }
  return -1
}
function Is-Extended([int]$vk) {
  return (@(0x25, 0x26, 0x27, 0x28, 0x24, 0x23, 0x21, 0x22, 0x2D, 0x2E) -contains $vk)
}
function Send-Vk([int]$vk, [bool]$down) {
  $flags = 0
  if (-not $down) { $flags = $flags -bor $KEYUP }
  if (Is-Extended $vk) { $flags = $flags -bor $EXT }
  [CuaNative]::keybd_event([byte]$vk, 0, [uint32]$flags, [IntPtr]::Zero)
}

function Get-Req {
  if (-not $Payload) { Fail "missing payload" }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
  return $json | ConvertFrom-Json
}

try { $req = Get-Req } catch { Fail "bad payload: $($_.Exception.Message)" }

$action = [string]$req.action

function Get-TargetWindow {
  $w = $req.window
  if ($null -eq $w -or "$w" -eq "") { return [IntPtr]::Zero }
  $s = "$w".Trim()
  $num = 0
  if ([int64]::TryParse($s, [ref]$num)) { return [IntPtr][int64]$num }
  $found = [IntPtr]::Zero
  $cb = [CuaNative+EnumProc]{
    param($h, $l)
    if (-not [CuaNative]::IsWindowVisible($h)) { return $true }
    $sb = New-Object System.Text.StringBuilder 512
    [void][CuaNative]::GetWindowText($h, $sb, 512)
    $t = $sb.ToString()
    if ($t -and $t.ToLower().Contains($s.ToLower())) { $script:found = $h; return $false }
    return $true
  }
  $script:found = [IntPtr]::Zero
  [void][CuaNative]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

try {
  switch ($action) {

    "cursor" {
      $p = New-Object CuaNative+POINT
      [void][CuaNative]::GetCursorPos([ref]$p)
      Emit @{ ok = $true; action = "cursor"; x = $p.X; y = $p.Y }
    }

    "screen" {
      $vw = [CuaNative]::GetSystemMetrics(78)
      $vh = [CuaNative]::GetSystemMetrics(79)
      $vx = [CuaNative]::GetSystemMetrics(76)
      $vy = [CuaNative]::GetSystemMetrics(77)
      Emit @{ ok = $true; action = "screen"; width = $vw; height = $vh; left = $vx; top = $vy }
    }

    "windows" {
      $script:items = New-Object System.Collections.ArrayList
      $cb = [CuaNative+EnumProc]{
        param($h, $l)
        if (-not [CuaNative]::IsWindowVisible($h)) { return $true }
        $sb = New-Object System.Text.StringBuilder 512
        [void][CuaNative]::GetWindowText($h, $sb, 512)
        $t = $sb.ToString().Trim()
        if (-not $t) { return $true }
        $r = New-Object CuaNative+RECT
        [void][CuaNative]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
        if ($w -le 0 -or $hh -le 0) { return $true }
        [uint32]$procId = 0
        [void][CuaNative]::GetWindowThreadProcessId($h, [ref]$procId)
        $pname = ""
        try { $pname = [System.Diagnostics.Process]::GetProcessById([int]$procId).ProcessName } catch { $pname = "" }
        [void]$script:items.Add([pscustomobject]@{
          hwnd = [int64]$h; title = $t; process = $pname; proc_id = [int]$procId;
          x = $r.Left; y = $r.Top; width = $w; height = $hh;
          minimized = [CuaNative]::IsIconic($h)
        })
        return $true
      }
      [void][CuaNative]::EnumWindows($cb, [IntPtr]::Zero)
      $list = $script:items | Sort-Object process, title
      Emit @{ ok = $true; action = "windows"; count = @($list).Count; windows = @($list) }
    }

    "focus" {
      $h = Get-TargetWindow
      if ($h -eq [IntPtr]::Zero) { Fail "window not found: $($req.window)" }
      [void][CuaNative]::ShowWindow($h, 9)
      [CuaNative]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
      [CuaNative]::keybd_event(0x12, 0, [uint32]$KEYUP, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 80
      $ok = [CuaNative]::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 120
      $fg = [CuaNative]::GetForegroundWindow()
      Emit @{ ok = $true; action = "focus"; hwnd = [int64]$h; foreground = [int64]$fg; success = [bool]$ok }
    }

    "screenshot" {
      $path = [string]$req.path
      if (-not $path) { Fail "path required" }
      $dir = Split-Path -Parent $path
      if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $h = Get-TargetWindow
      $bmp = $null
      if ($h -ne [IntPtr]::Zero) {
        $r = New-Object CuaNative+RECT
        [void][CuaNative]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
        if ($w -le 0 -or $hh -le 0) { Fail "window has no area" }
        $bmp = New-Object System.Drawing.Bitmap $w, $hh
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hh))
        $g.Dispose()
        $originX = $r.Left; $originY = $r.Top
      } else {
        $vw = [CuaNative]::GetSystemMetrics(78)
        $vh = [CuaNative]::GetSystemMetrics(79)
        $vx = [CuaNative]::GetSystemMetrics(76)
        $vy = [CuaNative]::GetSystemMetrics(77)
        $bmp = New-Object System.Drawing.Bitmap $vw, $vh
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vx, $vy, 0, 0, (New-Object System.Drawing.Size $vw, $vh))
        $g.Dispose()
        $originX = $vx; $originY = $vy
      }
      $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
      $w2 = $bmp.Width; $h2 = $bmp.Height
      $bmp.Dispose()
      Emit @{ ok = $true; action = "screenshot"; path = $path; width = $w2; height = $h2; origin_x = $originX; origin_y = $originY }
    }

    "move" {
      $ok = [CuaNative]::SetCursorPos([int]$req.x, [int]$req.y)
      Start-Sleep -Milliseconds 30
      Emit @{ ok = [bool]$ok; action = "move"; x = [int]$req.x; y = [int]$req.y }
    }

    "click" {
      $x = $req.x; $y = $req.y
      if ($null -ne $x -and $null -ne $y) { [void][CuaNative]::SetCursorPos([int]$x, [int]$y); Start-Sleep -Milliseconds 40 }
      $btn = "left"; if ($req.button) { $btn = ([string]$req.button).ToLower() }
      $count = 1; if ($req.count) { $count = [int]$req.count }
      $downF = $MOUSE.LEFTDOWN; $upF = $MOUSE.LEFTUP
      if ($btn -eq "right") { $downF = $MOUSE.RIGHTDOWN; $upF = $MOUSE.RIGHTUP }
      if ($btn -eq "middle") { $downF = $MOUSE.MIDDLEDOWN; $upF = $MOUSE.MIDDLEUP }
      for ($i = 0; $i -lt $count; $i++) {
        [CuaNative]::mouse_event([uint32]$downF, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 25
        [CuaNative]::mouse_event([uint32]$upF, 0, 0, 0, [IntPtr]::Zero)
        if ($i -lt $count - 1) { Start-Sleep -Milliseconds 60 }
      }
      Start-Sleep -Milliseconds 60
      $p = New-Object CuaNative+POINT
      [void][CuaNative]::GetCursorPos([ref]$p)
      Emit @{ ok = $true; action = "click"; x = $p.X; y = $p.Y; button = $btn; count = $count }
    }

    "drag" {
      $fx = [int]$req.from_x; $fy = [int]$req.from_y
      $tx = [int]$req.to_x; $ty = [int]$req.to_y
      $ms = 500; if ($req.duration) { $ms = [int]$req.duration }
      [void][CuaNative]::SetCursorPos($fx, $fy)
      Start-Sleep -Milliseconds 80
      [CuaNative]::mouse_event([uint32]$MOUSE.LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      $steps = 24
      for ($i = 1; $i -le $steps; $i++) {
        $px = [int]($fx + ($tx - $fx) * $i / $steps)
        $py = [int]($fy + ($ty - $fy) * $i / $steps)
        [void][CuaNative]::SetCursorPos($px, $py)
        Start-Sleep -Milliseconds ([math]::Max(1, [int]($ms / $steps)))
      }
      Start-Sleep -Milliseconds 80
      [CuaNative]::mouse_event([uint32]$MOUSE.LEFTUP, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      Emit @{ ok = $true; action = "drag"; from_x = $fx; from_y = $fy; to_x = $tx; to_y = $ty }
    }

    "scroll" {
      if ($null -ne $req.x -and $null -ne $req.y) { [void][CuaNative]::SetCursorPos([int]$req.x, [int]$req.y); Start-Sleep -Milliseconds 40 }
      $clicks = 1; if ($req.clicks) { $clicks = [int]$req.clicks }
      $dir = 1; if ($clicks -lt 0) { $dir = -1 }
      $n = [math]::Abs($clicks)
      for ($i = 0; $i -lt $n; $i++) {
        [CuaNative]::mouse_event([uint32]$MOUSE.WHEEL, 0, 0, (120 * $dir), [IntPtr]::Zero)
        Start-Sleep -Milliseconds 45
      }
      Emit @{ ok = $true; action = "scroll"; clicks = $clicks }
    }

    "type" {
      $text = [string]$req.text
      $prev = $null
      try { $prev = [System.Windows.Forms.Clipboard]::GetText() } catch { }
      $set = $false
      for ($i = 0; $i -lt 5 -and -not $set; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText($text); $set = $true } catch { Start-Sleep -Milliseconds 120 }
      }
      if (-not $set) { Fail "clipboard unavailable" }
      Start-Sleep -Milliseconds 80
      Send-Vk 0x11 $true
      Send-Vk 0x56 $true
      Send-Vk 0x56 $false
      Send-Vk 0x11 $false
      Start-Sleep -Milliseconds 150
      if ($null -ne $prev) {
        try { [System.Windows.Forms.Clipboard]::SetText($prev) } catch { }
      }
      Emit @{ ok = $true; action = "type"; length = $text.Length; method = "clipboard-paste" }
    }

    "key" {
      $keys = [string]$req.keys
      if (-not $keys) { Fail "keys required" }
      $parts = $keys.Split("+") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
      $vks = @()
      foreach ($p in $parts) {
        $vk = Get-Vk $p
        if ($vk -lt 0) { Fail "unknown key: $p" }
        $vks += $vk
      }
      for ($i = 0; $i -lt $vks.Count - 1; $i++) { Send-Vk $vks[$i] $true; Start-Sleep -Milliseconds 30 }
      Send-Vk $vks[$vks.Count - 1] $true
      Start-Sleep -Milliseconds 40
      Send-Vk $vks[$vks.Count - 1] $false
      for ($i = $vks.Count - 2; $i -ge 0; $i--) { Start-Sleep -Milliseconds 25; Send-Vk $vks[$i] $false }
      Start-Sleep -Milliseconds 60
      Emit @{ ok = $true; action = "key"; keys = $keys }
    }

    "wait" {
      $ms = 500; if ($req.ms) { $ms = [int]$req.ms }
      Start-Sleep -Milliseconds $ms
      Emit @{ ok = $true; action = "wait"; ms = $ms }
    }

    default { Fail "unknown action: $action" }
  }
} catch {
  Fail "$($_.Exception.Message)"
}
