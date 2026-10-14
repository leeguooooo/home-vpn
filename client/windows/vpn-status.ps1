# VPN 状态（只看不改，不需要管理员）。双击桌面的「VPN 状态」，弹窗显示，点确定关闭。
# -Quiet 时只打印不弹窗（给 SSH 里检查用）。日志：C:\ProgramData\sing-box-tools\vpn-switch.log
param([switch]$Quiet)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$log = 'C:\ProgramData\sing-box-tools\vpn-switch.log'
function Log($m) { try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') status $m" | Add-Content -Path $log -Encoding UTF8 } catch {} }

try {
    $running = [bool](Get-Process -Name sing-box -ErrorAction SilentlyContinue)
    $lines = @()
    $lines += if ($running) { 'VPN：已连接' } else { 'VPN：未连接' }
    try { $ip = curl.exe -s --max-time 10 https://ipinfo.io/json | ConvertFrom-Json } catch { $ip = $null }
    if ($ip) {
        $lines += "出口 IP：{0}（{1} {2}）" -f $ip.ip, $ip.country, $ip.org
        $lines += if ($ip.ip -eq '__SERVER_V4__') { '走__EXIT_NAME__的线路，可以登录 Claude / ChatGPT。' }
                  else { '这是中国 IP，不要在这个状态下登录 Claude / ChatGPT。' }
    } else {
        $lines += '出口 IP：查不到（网络不通，或正在切换）'
    }
    $t = Get-ScheduledTask -TaskName 'sing-box' -ErrorAction SilentlyContinue
    $lines += if (-not $t) { '开机自动连接：找不到任务，VPN 可能已卸载' }
              elseif ($t.State -eq 'Disabled') { '开机自动连接：否' } else { '开机自动连接：是' }
    $lines += ''
    $lines += '要切换，请双击桌面的「VPN 开关」。'
    $text = $lines -join "`r`n"
    Log ($lines[0] + ' | ' + $lines[1])
    if ($Quiet) { $text } else {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($text, 'VPN 状态', 'OK', 'Information')
    }
} catch {
    Log "ERROR $($_.Exception.Message)"
    if ($Quiet) { "ERROR: $($_.Exception.Message)" } else {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("出错了：`r`n$($_.Exception.Message)", 'VPN 状态', 'OK', 'Error')
    }
}
