# VPN 托盘图标（右下角）。绿点=已连接，红点=未连接；右键菜单可连接/断开。
# 开机自动启动（日常账号的启动文件夹 → vpn-tray.vbs → 本脚本）。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:TASK     = 'sing-box'
$script:TOGGLE   = 'C:\ProgramData\sing-box\vpn-toggle.ps1'
$script:LOG      = 'C:\ProgramData\sing-box-tools\vpn-switch.log'
$script:EXIT_IP  = '__SERVER_V4__'
$script:ip       = $null
$script:ipAt     = [DateTime]::MinValue
$script:lastRun  = $null

function Log($m) { try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') tray $m" | Add-Content -Path $script:LOG -Encoding UTF8 } catch {} }
function Running { [bool](Get-Process -Name sing-box -ErrorAction SilentlyContinue) }

function DotIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}
$script:iconOn  = DotIcon ([System.Drawing.Color]::FromArgb(40, 180, 70))
$script:iconOff = DotIcon ([System.Drawing.Color]::FromArgb(210, 60, 60))

function GetIP([switch]$Force) {
    if (-not $Force -and $script:ip -and ((Get-Date) - $script:ipAt).TotalMinutes -lt 5) { return $script:ip }
    try { $script:ip = curl.exe -s --max-time 8 https://ipinfo.io/json | ConvertFrom-Json } catch { $script:ip = $null }
    $script:ipAt = Get-Date
    return $script:ip
}

function Refresh([switch]$ForceIP) {
    $on = Running
    $notify.Icon = if ($on) { $script:iconOn } else { $script:iconOff }
    $ip = GetIP -Force:$ForceIP
    $where = if ($ip) { "$($ip.ip) $($ip.country)" } else { '出口 IP 未知' }
    $state = if ($on) { '已连接' } else { '未连接' }
    $tip = "VPN $state`n$where"
    if ($tip.Length -gt 62) { $tip = $tip.Substring(0, 62) }
    $notify.Text = $tip
    $miState.Text = "状态：$state　$where"
    $miConnect.Enabled = -not $on
    $miDisconnect.Enabled = $on
    $t = Get-ScheduledTask -TaskName $script:TASK -ErrorAction SilentlyContinue
    $miAuto.Checked = ($t -and $t.State -ne 'Disabled')
    if ($ip -and $ip.ip -ne $script:EXIT_IP -and $on) { $miState.Text += '（不是__EXIT_NAME__的 IP！）' }
}

function RunElevated([string]$arguments) {
    try {
        $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru -ErrorAction Stop
        $p.WaitForExit(40000) | Out-Null
        return $true
    } catch { Log "elevate failed: $($_.Exception.Message)"; return $false }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miState = $menu.Items.Add('状态：查询中…'); $miState.Enabled = $false
[void]$menu.Items.Add('-')
$miConnect = $menu.Items.Add('连接')
$miDisconnect = $menu.Items.Add('断开')
$miRefresh = $menu.Items.Add('刷新')
[void]$menu.Items.Add('-')
$miAuto = $menu.Items.Add('开机自动连接')
$miAuto.CheckOnClick = $false
$miLog = $menu.Items.Add('打开日志')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('退出托盘图标')
$notify.ContextMenuStrip = $menu

$miConnect.Add_Click({
    Log 'menu connect'
    [void](RunElevated "-NoProfile -ExecutionPolicy Bypass -File `"$script:TOGGLE`" -Quiet -Force")
    Refresh -ForceIP
    $notify.ShowBalloonTip(3000, 'VPN', $miState.Text, 'Info')
})
$miDisconnect.Add_Click({
    Log 'menu disconnect'
    [void](RunElevated "-NoProfile -ExecutionPolicy Bypass -File `"$script:TOGGLE`" -Quiet -Force")
    Refresh -ForceIP
    $notify.ShowBalloonTip(3000, 'VPN', $miState.Text, 'Info')
})
$miRefresh.Add_Click({ Refresh -ForceIP; $notify.ShowBalloonTip(2500, 'VPN', $miState.Text, 'Info') })
$miAuto.Add_Click({
    $t = Get-ScheduledTask -TaskName $script:TASK -ErrorAction SilentlyContinue
    if (-not $t) { return }
    $verb = if ($t.State -eq 'Disabled') { 'Enable-ScheduledTask' } else { 'Disable-ScheduledTask' }
    Log "menu auto -> $verb"
    [void](RunElevated "-NoProfile -Command `"$verb -TaskName $script:TASK | Out-Null`"")
    Refresh
})
$miLog.Add_Click({ Start-Process notepad.exe $script:LOG })
$miExit.Add_Click({ Log 'menu exit'; $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$notify.Add_MouseDoubleClick({ Refresh -ForceIP; $notify.ShowBalloonTip(2500, 'VPN', $miState.Text, 'Info') })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10000          # 本地查进程，便宜；出口 IP 最多 5 分钟取一次
$timer.Add_Tick({ Refresh })
$timer.Start()

Refresh -ForceIP
Log "started ($($miState.Text))"
[System.Windows.Forms.Application]::Run()
