# VPN 开关（__EXIT_NAME__出口）。双击桌面的「VPN 开关」，需要管理员。
# 先弹窗问「要断开吗 / 要连接吗」，选「是」才切换，结束再弹结果。只看状态用「VPN 状态」。
# -Quiet 只打印不弹窗；-Force 跳过确认（两个都给 SSH 里检查用）。
param([switch]$Quiet, [switch]$Force)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$task = 'sing-box'
$log = 'C:\ProgramData\sing-box-tools\vpn-switch.log'
function Log($m) { try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') toggle $m" | Add-Content -Path $log -Encoding UTF8 } catch {} }
function Running { [bool](Get-Process -Name sing-box -ErrorAction SilentlyContinue) }
function ExitIPLine {
    try { $ip = curl.exe -s --max-time 10 https://ipinfo.io/json | ConvertFrom-Json } catch { $ip = $null }
    if (-not $ip) { return '出口 IP：查不到（网络不通，或正在切换）' }
    $l = "出口 IP：{0}（{1} {2}）" -f $ip.ip, $ip.country, $ip.org
    if ($ip.ip -eq '__SERVER_V4__') { return "$l`r`n走__EXIT_NAME__的线路，可以登录 Claude / ChatGPT。" }
    return "$l`r`n这是中国 IP，不要在这个状态下登录 Claude / ChatGPT。"
}
function Ask($text) {
    if ($Force) { return $true }
    if ($Quiet) { return $false }
    Add-Type -AssemblyName System.Windows.Forms
    return ([System.Windows.Forms.MessageBox]::Show($text, 'VPN 开关', 'YesNo', 'Question') -eq 'Yes')
}
function Done($text, $icon) {
    Log ($text -replace "`r`n", ' | ')
    if ($Quiet) { $text } else {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($text, 'VPN 开关', 'OK', $icon)
    }
}

try {
    if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
        Done "找不到计划任务 $task，VPN 可能已被卸载。" 'Error'; exit 1
    }
    $ipLine = ExitIPLine
    if (Running) {
        if (-not (Ask "当前：已连接`r`n$ipLine`r`n`r`n要断开吗？断开后就是中国 IP。")) { Done "已取消，保持连接。`r`n$ipLine" 'Information'; exit 0 }
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (Running) { Stop-Process -Name sing-box -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        $state = if (Running) { '断开失败（还在运行）' } else { '已断开' }
    } else {
        if (-not (Ask "当前：未连接`r`n$ipLine`r`n`r`n要连接吗？")) { Done "已取消，保持断开。`r`n$ipLine" 'Information'; exit 0 }
        Start-ScheduledTask -TaskName $task
        for ($i = 0; $i -lt 15 -and -not (Running); $i++) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 3
        $state = if (Running) { '已连接' } else { '启动失败' }
    }
    $t = Get-ScheduledTask -TaskName $task
    $auto = if ($t.State -eq 'Disabled') { '否' } else { '是' }
    Done "$state`r`n$(ExitIPLine)`r`n开机自动连接：$auto" 'Information'
} catch {
    Done "出错了：`r`n$($_.Exception.Message)" 'Error'
    exit 1
}
