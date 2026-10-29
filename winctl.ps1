<#
    winctl.ps1 - Windows 桌面键鼠控制工具
    供 astrbot_plugin_winhands 调用。全部操作走真实输入事件（SendInput），
    不往窗口里塞值，所以对大多数桌面程序有效。
    每个子命令输出一行 JSON，便于调用方解析。
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('info','pos','move','click','type','key','shot','windows','rect','focus','controls','uia-click','close')]
    [string]$Action = 'info',

    [int]$X = -1,
    [int]$Y = -1,
    [string]$Text = '',
    [string]$Out = '',
    [string]$Title = '',
    [string]$Name = '',
    [string]$Button = 'left',
    [string]$Region = '',
    [int]$Steps = 6,

    [int]$MaxWidth = 0
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Emit([hashtable]$o) {
    $o['ok'] = $true
    $o['action'] = $Action
    $o | ConvertTo-Json -Compress -Depth 8
    exit 0
}
function Fail([string]$msg) {
    @{ ok = $false; action = $Action; error = $msg } | ConvertTo-Json -Compress -Depth 4
    exit 1
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WinCtl {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static void MouseEvent(uint flags) {
        INPUT[] a = new INPUT[1];
        a[0].type = 0; a[0].u.mi.dx = 0; a[0].u.mi.dy = 0; a[0].u.mi.mouseData = 0;
        a[0].u.mi.dwFlags = flags; a[0].u.mi.time = 0; a[0].u.mi.dwExtraInfo = IntPtr.Zero;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void UniChar(char c) {
        INPUT[] a = new INPUT[2];
        a[0].type = 1; a[0].u.ki.wVk = 0; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = 0x0004; a[0].u.ki.time = 0; a[0].u.ki.dwExtraInfo = IntPtr.Zero;
        a[1] = a[0]; a[1].u.ki.dwFlags = 0x0006;
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Vk(ushort vk, bool up) {
        INPUT[] a = new INPUT[1];
        a[0].type = 1; a[0].u.ki.wVk = vk; a[0].u.ki.wScan = 0; a[0].u.ki.dwFlags = up ? (uint)0x0002 : 0u; a[0].u.ki.time = 0; a[0].u.ki.dwExtraInfo = IntPtr.Zero;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Combo(int[] mods, int key) {
        for (int i = 0; i < mods.Length; i++) Vk((ushort)mods[i], false);
        Vk((ushort)key, false); Vk((ushort)key, true);
        for (int i = mods.Length - 1; i >= 0; i--) Vk((ushort)mods[i], true);
    }
    public static string Title(IntPtr h) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        return sb.ToString();
    }
}
'@
Add-Type -TypeDefinition $cs
[void][WinCtl]::SetProcessDPIAware()

function Get-MainWindow([string]$pattern) {
    $p = Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -match $pattern } | Select-Object -First 1
    return $p
}

switch ($Action) {

    'info' {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $fg = [WinCtl]::GetForegroundWindow()
        $pt = New-Object WinCtl+POINT
        [void][WinCtl]::GetCursorPos([ref]$pt)
        Emit @{
            os          = [System.Environment]::OSVersion.VersionString
            ps_version  = $PSVersionTable.PSVersion.ToString()
            screen      = "$($vs.Width)x$($vs.Height)"
            cursor      = @($pt.X, $pt.Y)
            foreground  = [WinCtl]::Title($fg)
        }
    }

    'pos' {
        $pt = New-Object WinCtl+POINT
        [void][WinCtl]::GetCursorPos([ref]$pt)
        Emit @{ x = $pt.X; y = $pt.Y }
    }

    'move' {
        if ($X -lt 0 -or $Y -lt 0) { Fail 'need -X and -Y' }
        $pt = New-Object WinCtl+POINT
        [void][WinCtl]::GetCursorPos([ref]$pt)
        if ($Steps -le 1) {
            [void][WinCtl]::SetCursorPos($X, $Y)
        } else {
            for ($i = 1; $i -le $Steps; $i++) {
                $nx = [int]($pt.X + ($X - $pt.X) * $i / $Steps)
                $ny = [int]($pt.Y + ($Y - $pt.Y) * $i / $Steps)
                [void][WinCtl]::SetCursorPos($nx, $ny)
                Start-Sleep -Milliseconds 20
            }
        }
        $now = New-Object WinCtl+POINT
        [void][WinCtl]::GetCursorPos([ref]$now)
        Emit @{ x = $now.X; y = $now.Y }
    }

    'click' {
        if ($X -ge 0 -and $Y -ge 0) {
            [void][WinCtl]::SetCursorPos($X, $Y)
            Start-Sleep -Milliseconds 60
        }
        if ($Button -eq 'right') { $down = 0x0008; $up = 0x0010 }
        elseif ($Button -eq 'middle') { $down = 0x0020; $up = 0x0040 }
        else { $down = 0x0002; $up = 0x0004 }
        [WinCtl]::MouseEvent([uint32]$down)
        Start-Sleep -Milliseconds 40
        [WinCtl]::MouseEvent([uint32]$up)
        $now = New-Object WinCtl+POINT
        [void][WinCtl]::GetCursorPos([ref]$now)
        Emit @{ button = $Button; x = $now.X; y = $now.Y }
    }

    'type' {
        if (-not $Text) { Fail 'need -Text' }
        $n = 0
        foreach ($ch in $Text.ToCharArray()) {
            [WinCtl]::UniChar($ch)
            Start-Sleep -Milliseconds 8
            $n++
        }
        Emit @{ chars = $n }
    }

    'key' {
        if (-not $Text) { Fail 'need -Text' }
        $mods = @()
        $parts = $Text -split '\+'
        $last = $parts[$parts.Count - 1].Trim().ToUpper()
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            switch ($parts[$i].Trim().ToUpper()) {
                'CTRL'  { $mods += 0x11 }
                'SHIFT' { $mods += 0x10 }
                'ALT'   { $mods += 0x12 }
                'WIN'   { $mods += 0x5B }
                default { Fail "unknown modifier: $($parts[$i])" }
            }
        }
        $map = @{
            'ENTER' = 0x0D; 'TAB' = 0x09; 'ESC' = 0x1B; 'SPACE' = 0x20; 'BACKSPACE' = 0x08
            'DELETE' = 0x2E; 'INSERT' = 0x2D; 'HOME' = 0x24; 'END' = 0x23
            'PGUP' = 0x21; 'PGDN' = 0x22
            'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
            'F1' = 0x70; 'F2' = 0x71; 'F3' = 0x72; 'F4' = 0x73; 'F5' = 0x74; 'F6' = 0x75
            'F7' = 0x76; 'F8' = 0x77; 'F9' = 0x78; 'F10' = 0x79; 'F11' = 0x7A; 'F12' = 0x7B
        }
        if ($map.ContainsKey($last)) { $vk = [int]$map[$last] }
        elseif ($last.Length -eq 1) { $vk = [int][char]$last }
        else { Fail "unknown key: $last" }

        if ($mods.Count -eq 0) {
            [WinCtl]::Vk([uint16]$vk, $false)
            Start-Sleep -Milliseconds 40
            [WinCtl]::Vk([uint16]$vk, $true)
        } else {
            foreach ($m in $mods) { [WinCtl]::Vk([uint16]$m, $false); Start-Sleep -Milliseconds 60 }
            [WinCtl]::Vk([uint16]$vk, $false)
            Start-Sleep -Milliseconds 60
            [WinCtl]::Vk([uint16]$vk, $true)
            Start-Sleep -Milliseconds 60
            for ($i = $mods.Count - 1; $i -ge 0; $i--) { [WinCtl]::Vk([uint16]$mods[$i], $true); Start-Sleep -Milliseconds 40 }
        }
        Emit @{ sent = $Text }
    }

    'shot' {
        if (-not $Out) { Fail 'need -Out' }
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $sx = $vs.X; $sy = $vs.Y; $sw = $vs.Width; $sh = $vs.Height
        if ($Region) {
            $p = $Region -split ','
            if ($p.Count -eq 4) {
                $sx = [int]$p[0]; $sy = [int]$p[1]; $sw = [int]$p[2]; $sh = [int]$p[3]
            } else { Fail 'region must be x,y,width,height' }
        }
        $bmp = New-Object System.Drawing.Bitmap($sw, $sh)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($sx, $sy, 0, 0, $bmp.Size)
        if ($MaxWidth -gt 0 -and $sw -gt $MaxWidth) {
            $ratio = $MaxWidth / $sw
            $nw = [int]$MaxWidth
            $nh = [int][Math]::Round($sh * $ratio)
            $small = New-Object System.Drawing.Bitmap($nw, $nh)
            $gs = [System.Drawing.Graphics]::FromImage($small)
            $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $gs.DrawImage($bmp, 0, 0, $nw, $nh)
            $gs.Dispose()
            $bmp.Dispose()
            $bmp = $small
            $sw = $nw
            $sh = $nh
        }
        $dir = Split-Path -Parent $Out
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        $kb = [int]((Get-Item $Out).Length / 1024)
        Emit @{ file = $Out; width = $sw; height = $sh; kb = $kb }
    }

    'windows' {
        $arr = @()
        foreach ($p in (Get-Process | Where-Object { $_.MainWindowTitle })) {
            $r = New-Object WinCtl+RECT
            [void][WinCtl]::GetWindowRect($p.MainWindowHandle, [ref]$r)
            $arr += @{
                title  = $p.MainWindowTitle
                name   = $p.ProcessName
                pid    = $p.Id
                rect   = "$($r.Left),$($r.Top),$($r.Right - $r.Left),$($r.Bottom - $r.Top)"
            }
        }
        Emit @{ count = $arr.Count; windows = @($arr) }
    }

    'rect' {
        if (-not $Title) { Fail 'need -Title' }
        $p = Get-MainWindow $Title
        if (-not $p) { Fail "no window matching: $Title" }
        $r = New-Object WinCtl+RECT
        [void][WinCtl]::GetWindowRect($p.MainWindowHandle, [ref]$r)
        Emit @{
            title  = $p.MainWindowTitle
            pid    = $p.Id
            x      = $r.Left
            y      = $r.Top
            width  = $r.Right - $r.Left
            height = $r.Bottom - $r.Top
        }
    }

    'focus' {
        if (-not $Title) { Fail 'need -Title' }
        $p = Get-MainWindow $Title
        if (-not $p) { Fail "no window matching: $Title" }
        $h = $p.MainWindowHandle
        if ([WinCtl]::IsIconic($h)) { [void][WinCtl]::ShowWindow($h, 9) }
        [void][WinCtl]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 350
        $cur = [WinCtl]::Title([WinCtl]::GetForegroundWindow())
        Emit @{ verified = ($cur -eq $p.MainWindowTitle); foreground = $cur; expected = $p.MainWindowTitle }
    }

    'controls' {
        if ($Title) {
            $p = Get-MainWindow $Title
            if (-not $p) { Fail "no window matching: $Title" }
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
        } else {
            $fg = [WinCtl]::GetForegroundWindow()
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($fg)
        }
        if (-not $root) { Fail 'cannot attach to window' }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($found.Count -eq 0 -and -not $Title) {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        }
        $arr = @()
        foreach ($b in $found) {
            $c = $b.Current
            if (-not $c.Name) { continue }
            $r = $c.BoundingRectangle
            $arr += @{
                name = $c.Name
                id   = $c.AutomationId
                x    = [int]($r.X + $r.Width / 2)
                y    = [int]($r.Y + $r.Height / 2)
            }
        }
        Emit @{ window = $root.Current.Name; count = $arr.Count; controls = @($arr) }
    }

    'uia-click' {
        if (-not $Name) { Fail 'need -Name' }
        if ($Title) {
            $p = Get-MainWindow $Title
            if (-not $p) { Fail "no window matching: $Title" }
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
        } else {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([WinCtl]::GetForegroundWindow())
        }
        if (-not $root) { Fail 'cannot attach to window' }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        $hit = $null
        foreach ($b in $found) {
            if ($b.Current.Name -match $Name) { $hit = $b; break }
        }
        if (-not $hit) {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
            foreach ($b in $found) {
                if ($b.Current.Name -match $Name) { $hit = $b; break }
            }
        }
        if (-not $hit) { Fail "no button matching: $Name" }
        $r = $hit.Current.BoundingRectangle
        $cx = [int]($r.X + $r.Width / 2)
        $cy = [int]($r.Y + $r.Height / 2)
        [void][WinCtl]::SetCursorPos($cx, $cy)
        Start-Sleep -Milliseconds 80
        [WinCtl]::MouseEvent([uint32]0x0002)
        Start-Sleep -Milliseconds 40
        [WinCtl]::MouseEvent([uint32]0x0004)
        Emit @{ clicked = $hit.Current.Name; x = $cx; y = $cy }
    }

    'close' {
        if (-not $Title) { Fail 'need -Title' }
        $p = Get-MainWindow $Title
        if (-not $p) { Fail "no window matching: $Title" }
        $title = $p.MainWindowTitle
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
        try {
            $wp = $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
            $wp.Close()
        } catch {
            [void][WinCtl]::Vk([uint16]0x12, $false)
            Start-Sleep -Milliseconds 60
            [void][WinCtl]::Vk([uint16]0x73, $false)
            Start-Sleep -Milliseconds 60
            [void][WinCtl]::Vk([uint16]0x73, $true)
            Start-Sleep -Milliseconds 60
            [void][WinCtl]::Vk([uint16]0x12, $true)
        }
        Start-Sleep -Milliseconds 400
        Emit @{ closed = $title }
    }

    default { Fail "unknown action: $Action" }
}
