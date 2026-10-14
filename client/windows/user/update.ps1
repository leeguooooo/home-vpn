# __BRAND__ · 自动更新配置（计划任务 __APP_ID__-Update 以 SYSTEM 每 6 小时和开机时跑；托盘「立即更新」也会触发它）。
# 从订阅拉 Windows 版 sing-box 配置 → sing-box check 通过 → 和现在的不同才替换 → 正在连接就重启一下。
# 拉不到、校验不过：什么都不动，旧配置照用。账号到期（410）：写 status\expired，托盘会提示。
# -Install：安装时调用，失败时最后一行是给人看的原因，退出码非 0。
param([switch]$Install)
$ErrorActionPreference = 'Stop'
$Dir = 'C:\ProgramData\__APP_ID__'
$Task = '__APP_ID__'
$log = "$Dir\update.log"
function Log($m) { try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $log -Encoding UTF8 } catch {} }
function Status($name, $text) { [IO.File]::WriteAllText("$Dir\status\$name", $text, (New-Object Text.UTF8Encoding $false)) }
function Quit($code, $why) { Log $why; if ($Install) { $why }; exit $code }

$url = (Get-Content "$Dir\sub.txt" -Raw).Trim()
$new = "$Dir\config.new.json"
$code = & curl.exe -sS -m 60 --retry 2 -A 'home-vpn-windows/1' -o $new -w '%{http_code}' "$url/singbox-windows" 2>$null
if ($code -eq '410') {
    Status 'expired' (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Quit 3 '账号已到期：找给你链接的人续期。'
}
if ($code -eq '404') { Quit 4 '订阅链接已失效（可能换了新链接）：找给你链接的人要新的，用新链接重新安装。' }
if ($code -ne '200') { Quit 2 "连不上订阅服务（$code）。检查一下网络再试。" }
Remove-Item "$Dir\status\expired" -ErrorAction SilentlyContinue

$check = & "$Dir\sing-box.exe" check -D $Dir -c $new 2>&1
if ($LASTEXITCODE -ne 0) { Remove-Item $new -ErrorAction SilentlyContinue; Quit 5 "新配置没通过检查，保留旧配置：$check" }
$cur = "$Dir\config.json"
if ((Test-Path $cur) -and ((Get-FileHash $cur).Hash -eq (Get-FileHash $new).Hash)) {
    Remove-Item $new; Status 'updated' (Get-Date -Format 'yyyy-MM-dd HH:mm'); Quit 0 '配置没变化'
}
Move-Item $new $cur -Force
Status 'updated' (Get-Date -Format 'yyyy-MM-dd HH:mm')
if (-not $Install -and (Get-Process sing-box -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir\*" })) {
    Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $Task
    Quit 0 '配置已更新，已重连'
}
Quit 0 '配置已更新'
