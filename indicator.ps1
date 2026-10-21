$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$code = @'
using System;
using System.Runtime.InteropServices;
public class HudWin {
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
Add-Type -TypeDefinition $code
[void][HudWin]::SetProcessDPIAware()

$cfgDir = Join-Path $env:LOCALAPPDATA "dsh-computer"
$cfgPath = Join-Path $cfgDir "hud.json"
$logPath = Join-Path $env:TEMP "dsh-hud.log"
function Log($m) { try { "$([DateTime]::Now.ToString('HH:mm:ss.fff')) $m" | Out-File -FilePath $logPath -Append -Encoding utf8 } catch { } }

function Load-Scale {
  try {
    if (Test-Path $cfgPath) {
      $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.scale) { return [double]$j.scale }
    }
  } catch { }
  return 1.0
}
function Save-Scale($s) {
  try {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
    @{ scale = [math]::Round($s, 2) } | ConvertTo-Json -Compress | Set-Content -Path $cfgPath -Encoding UTF8
  } catch { }
}

$BASE_W = 300.0
$BASE_H = 46.0

$enc = New-Object System.Text.UTF8Encoding($false)
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $enc)
$script:pending = $stdin.ReadLineAsync()

$form = New-Object System.Windows.Forms.Form
$form.Text = "DeepSeek Computer Use HUD"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 30)
$form.Opacity = 0.0
$form.Visible = $false

$dot = New-Object System.Windows.Forms.Panel
$dot.BackColor = [System.Drawing.Color]::FromArgb(86, 180, 255)

$label = New-Object System.Windows.Forms.Label
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$label.ForeColor = [System.Drawing.Color]::FromArgb(234, 238, 246)
$label.BackColor = [System.Drawing.Color]::Transparent
$label.Text = ""

$form.Controls.Add($dot)
$form.Controls.Add($label)

function RoundPath($w, $h, $r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc(0, 0, $d, $d, 180, 90)
  $p.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
  $p.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
  $p.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function Apply-Scale($s, $textPx) {
  if ($s -lt 0.6) { $s = 0.6 }
  if ($s -gt 2.5) { $s = 2.5 }
  $script:scale = $s
  if ($null -eq $textPx) { $textPx = 0 }

  $w = [int][math]::Round($BASE_W * $s)
  $h = [int][math]::Round($BASE_H * $s)
  $r = [int][math]::Max(4, [math]::Round(12 * $s))
  $dsize = [int][math]::Max(5, [math]::Round(8 * $s))
  $dp = [int][math]::Round(16 * $s)
  $lx = [int][math]::Round(34 * $s)
  $fs = [double][math]::Max(7.5, 10 * $s)

  $needW = $lx + [int]$textPx + [int][math]::Round(16 * $s)
  if ($needW -gt $w) { $w = $needW }
  $maxW = [int][math]::Round(760 * $s)
  if ($w -gt $maxW) { $w = $maxW }

  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $x = $wa.Right - $w - [int][math]::Round(22 * $s)
  $y = $wa.Bottom - $h - [int][math]::Round(22 * $s)

  $form.Bounds = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
  if ($form.Region) { $form.Region.Dispose() }
  $form.Region = New-Object System.Drawing.Region((RoundPath $w $h $r))

  $dy = [int](($h - $dsize) / 2)
  $dot.Bounds = New-Object System.Drawing.Rectangle($dp, $dy, $dsize, $dsize)
  if ($dot.Region) { $dot.Region.Dispose() }
  $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $rp.AddEllipse(0, 0, $dsize, $dsize)
  $dot.Region = New-Object System.Drawing.Region($rp)

  $label.Bounds = New-Object System.Drawing.Rectangle($lx, 0, ($w - $lx - 4), $h)
  $label.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", $fs, [System.Drawing.FontStyle]::Regular)

  Log "scale=$s size=${w}x${h}"
}

$form.add_Shown({
  $hh = $form.Handle
  $ex = [HudWin]::GetWindowLong($hh, -20)
  $ex = $ex -bor 0x08000000 -bor 0x00000080
  [void][HudWin]::SetWindowLong($hh, -20, $ex)
})

$script:target = 0.0
$script:phase = 0.0
$script:holdUntil = 0
$script:scale = Load-Scale
Apply-Scale $script:scale

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.add_Tick({
  $script:phase += 0.16
  $pulse = 0.55 + 0.45 * [math]::Sin($script:phase)
  $c = [int](120 + 120 * $pulse)
  if ($c -gt 255) { $c = 255 }
  $dot.BackColor = [System.Drawing.Color]::FromArgb($c, 200, 255)

  if ($script:pending -and $script:pending.IsCompleted) {
    $line = $script:pending.Result
    if ($null -eq $line) {
      $form.Close()
      return
    }
    if ($line.StartsWith("show|")) {
      $txt = $line.Substring(5)
      $label.Text = $txt
      $tw = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $label.Font).Width
      Apply-Scale $script:scale $tw
      $script:target = 0.94
      $script:holdUntil = (Get-Date).AddMilliseconds(900).Ticks
      if (-not $form.Visible) { $form.Show() }
    } elseif ($line -eq "hide") {
      $script:target = 0.0
    } elseif ($line.StartsWith("scale|")) {
      $sv = 0.0
      if ([double]::TryParse($line.Substring(6), [ref]$sv)) {
        Apply-Scale $sv
        Save-Scale $sv
      }
    }
    $script:pending = $stdin.ReadLineAsync()
  }

  if ($form.Visible) {
    if ((Get-Date).Ticks -lt $script:holdUntil -and $script:target -eq 0.0) {
    } elseif ([math]::Abs($form.Opacity - $script:target) -gt 0.02) {
      if ($form.Opacity -lt $script:target) {
        $form.Opacity = [math]::Min($script:target, $form.Opacity + 0.14)
      } else {
        $form.Opacity = [math]::Max($script:target, $form.Opacity - 0.09)
      }
    } elseif ($script:target -eq 0.0 -and $form.Opacity -le 0.03) {
      $form.Hide()
    }
  }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Transparent)
$bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(28, 30, 38))
$g.FillEllipse($bg, 1, 1, 30, 30)
$fg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(86, 180, 255))
$g.FillEllipse($fg, 9, 9, 14, 14)
$g.Dispose()
$tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$tray.Text = "DeepSeek 电脑操控提示"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$title = New-Object System.Windows.Forms.ToolStripMenuItem "提示框大小"
$title.Enabled = $false
[void]$menu.Items.Add($title)

foreach ($pct in @(75, 100, 125, 150, 200)) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem ("{0}%" -f $pct)
  $item.Tag = $pct
  $item.add_Click({
    param($sender, $e)
    $s = [double]$sender.Tag / 100.0
    Apply-Scale $s
    Save-Scale $s
    foreach ($it in $menu.Items) {
      if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.Tag) {
        $it.Checked = ([double]$it.Tag / 100.0 -eq $s)
      }
    }
  })
  [void]$menu.Items.Add($item)
  if ([math]::Abs(([double]$pct / 100.0) - $script:scale) -lt 0.001) { $item.Checked = $true }
}

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$quit = New-Object System.Windows.Forms.ToolStripMenuItem "关闭提示（下次操作自动重启）"
$quit.add_Click({ $form.Close() })
[void]$menu.Items.Add($quit)
$tray.ContextMenuStrip = $menu

$form.add_FormClosed({
  $tray.Visible = $false
  $tray.Dispose()
  $timer.Stop()
})

$timer.Start()
try {
  [System.Windows.Forms.Application]::Run($form)
} catch {
  Log "run error: $($_.Exception.Message)"
}
Log "exit"
