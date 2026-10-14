# __BRAND__ · 托盘图标（右下角）。登录时由启动项「__BRAND__」打开，以当前用户身份运行（不需要管理员）。
# 绿点 = 已连接（__EXIT_NAME__），灰点 = 未连接，橙点 = 有问题（账号到期 / 出口不是__EXIT_NAME__）。点图标弹出菜单。
# 连接 / 断开 = 启动 / 停止计划任务 __APP_ID__（安装时给普通用户开了这个权限，所以不弹管理员确认）。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dir = 'C:\ProgramData\__APP_ID__'
$App = "$Dir\app"
$Task = '__APP_ID__'
$ExitCC = '__EXIT_COUNTRY__'   # ISO country code of the exit (site.env EXIT_COUNTRY); empty = not checked

# one tray per user session
$mutex = New-Object System.Threading.Mutex($false, "Local\__APP_ID__Tray")
if (-not $mutex.WaitOne(0)) { exit }

function Dot([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $c), 4, 4, 24, 24)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 0, 0, 0)), 2), 4, 4, 24, 24)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icons = @{
    on   = Dot ([System.Drawing.Color]::FromArgb(40, 180, 80))
    off  = Dot ([System.Drawing.Color]::FromArgb(150, 150, 150))
    warn = Dot ([System.Drawing.Color]::FromArgb(235, 150, 30))
    busy = Dot ([System.Drawing.Color]::FromArgb(70, 140, 230))
}

$script:ip = $null
$script:ipAt = [DateTime]::MinValue
$script:last = $null
$script:busyUntil = [DateTime]::MinValue

function TaskState { $t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue; if ($t) { [string]$t.State } else { 'Missing' } }
function AutoStart {
    $t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    [bool]($t -and ($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and $_.Enabled }))
}
function ExitIP([switch]$Force) {
    if ($Force -or ((Get-Date) - $script:ipAt).TotalMinutes -ge 5) {
        try { $script:ip = Invoke-RestMethod -UseBasicParsing -TimeoutSec 8 'https://ipinfo.io/json' } catch { $script:ip = $null }
        $script:ipAt = Get-Date
    }
    $script:ip
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miState = $menu.Items.Add('正在查询……'); $miState.Enabled = $false
$miWhere = $menu.Items.Add(''); $miWhere.Enabled = $false
[void]$menu.Items.Add('-')
$miToggle = $menu.Items.Add('连接')
$miToggle.Font = New-Object System.Drawing.Font($miToggle.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add('-')
$miAuto = $menu.Items.Add('开机自动连接')
$miUpdate = $menu.Items.Add('立即更新配置')
$miHelp = $menu.Items.Add('使用说明')
[void]$menu.Items.Add('-')
$miUninstall = $menu.Items.Add('卸载__BRAND__…')
$miExit = $menu.Items.Add('隐藏这个图标（不影响连接）')
$notify.ContextMenuStrip = $menu

function Refresh([switch]$ForceIP, [switch]$Announce) {
    $state = TaskState
    $on = $state -eq 'Running'
    $expired = Test-Path "$Dir\status\expired"
    $ip = if ($on) { ExitIP -Force:$ForceIP } else { $null }
    $atExit = $on -and $ip -and (-not $ExitCC -or $ip.country -eq $ExitCC)

    if ($state -eq 'Missing') {
        $key = 'warn'; $text = '__BRAND__没装好'; $where = '重新运行一次安装命令'
    } elseif ($expired) {
        $key = 'warn'; $text = '账号已到期'; $where = '找给你链接的人续期'
    } elseif ((Get-Date) -lt $script:busyUntil) {
        $key = 'busy'; $text = if ($on) { '正在连接……' } else { '正在断开……' }; $where = ''
    } elseif ($on -and $atExit) {
        $key = 'on'; $text = '已连接 · __EXIT_NAME__'; $where = "出口 IP：$($ip.ip)"
    } elseif ($on -and $ip) {
        $key = 'warn'; $text = '已连接，但出口不是__EXIT_NAME__'; $where = "出口 IP：$($ip.ip)（$($ip.country)），稍等一会儿再看"
    } elseif ($on) {
        $key = 'busy'; $text = '已连接，正在确认线路……'; $where = ''
    } else {
        $key = 'off'; $text = '未连接（直连，中国 IP）'; $where = '点「连接」走__BRAND__'
    }
    $notify.Icon = $icons[$key]
    $tip = "__BRAND__：$text"
    $notify.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip }
    $miState.Text = $text
    $miWhere.Text = $where
    $miWhere.Visible = [bool]$where
    $miToggle.Text = if ($on) { '断开' } else { '连接' }
    $miToggle.Enabled = $state -ne 'Missing' -and -not $expired
    $miAuto.Checked = AutoStart
    if ($Announce -or ($script:last -and $script:last -ne $key -and $key -ne 'busy')) {
        $tipIcon = if ($key -eq 'warn') { 'Warning' } else { 'Info' }
        $notify.ShowBalloonTip(4000, '__BRAND__', ($text + $(if ($where) { "`n$where" })), $tipIcon)
    }
    $script:last = $key
}

$miToggle.Add_Click({
    $on = (TaskState) -eq 'Running'
    $script:busyUntil = (Get-Date).AddSeconds(8)
    try {
        if ($on) { Stop-ScheduledTask -TaskName $Task } else { Start-ScheduledTask -TaskName $Task }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("操作没成功：$($_.Exception.Message)`n`n重新运行一次安装命令可以修复。", '__BRAND__', 'OK', 'Warning')
    }
    Refresh
    # re-check once the tunnel has settled
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 6000
    $t.Add_Tick({ $this.Stop(); $script:busyUntil = [DateTime]::MinValue; Refresh -ForceIP -Announce })
    $t.Start()
})
$miAuto.Add_Click({
    $want = if (AutoStart) { 'Off' } else { 'On' }
    try {
        $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$App\autostart.ps1`" -$want"
        $p.WaitForExit(30000) | Out-Null
    } catch {}
    Refresh
})
$miUpdate.Add_Click({
    try { Start-ScheduledTask -TaskName "$Task-Update" } catch {}
    $notify.ShowBalloonTip(3000, '__BRAND__', '正在更新配置，有变化会自动重连。', 'Info')
})
$miHelp.Add_Click({
    try { Start-Process ((Get-Content "$App\help.txt" -Raw).Trim()) } catch {}
})
$miUninstall.Add_Click({
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$App\uninstall.ps1`"" } catch {}
})
$miExit.Add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
# a left click opens the same menu (people expect something to happen when they click the icon)
$notify.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $m = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $m.Invoke($notify, $null)
    }
})
$menu.Add_Opening({ Refresh })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10000
$timer.Add_Tick({ Refresh })
$timer.Start()

Refresh -ForceIP
[System.Windows.Forms.Application]::Run()
$notify.Visible = $false
