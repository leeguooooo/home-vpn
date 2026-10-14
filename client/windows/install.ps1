# Windows 客户端安装（由 Mac 上的 client/windows/install.sh 通过 ssh 以管理员身份调用；也可以在本机管理员 PowerShell 里跑）。
# 文件先放在 -Stage 目录：config.json、*.srs、vpn-*.ps1、vpn-tray.vbs，可选 sing-box.exe。
#   -DesktopUser  平时坐在这台电脑前用的账号（桌面图标、开机托盘装给他），默认当前账号
#   -Apply        配置有变化时立即重启 VPN：先挂一个 5 分钟后恢复旧配置的回滚任务，出口验证对了再撤掉
# 可重复运行；没变化的步骤跳过。
param(
  [Parameter(Mandatory = $true)][string]$Stage,
  [string]$DesktopUser = $env:USERNAME,
  [string]$ServerV4,
  [switch]$Apply,
  [switch]$CnExit,          # this machine is the 回国 exit: reverse ssh tunnel to the server
  [string]$CnServer,
  [string]$CnUser,
  [int]$CnPort = 18090
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$Dir = 'C:\ProgramData\sing-box'
$Tools = 'C:\ProgramData\sing-box-tools'
$Task = 'sing-box'
$Slug = '__SLUG__'            # filled in by client/windows/install.sh (site.env SLUG)
function Say($m) { Write-Output "== $m" }
function Running { [bool](Get-Process -Name sing-box -ErrorAction SilentlyContinue) }
function Same($a, $b) { (Test-Path $a) -and (Test-Path $b) -and ((Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash) }

New-Item -ItemType Directory -Force $Dir, $Tools, "$Dir\backups" | Out-Null
# config dir: SYSTEM + Administrators only (the config holds node passwords)
icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

# ---------------------------------------------------------------- binary, rule sets, config
$wasRunning = Running
$exeChanged = $false
if (Test-Path "$Stage\sing-box.exe") {
  if (-not (Same "$Stage\sing-box.exe" "$Dir\sing-box.exe")) {
    Say "更新 sing-box.exe"
    if ($wasRunning) { Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue; Stop-Process -Name sing-box -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
    Copy-Item "$Stage\sing-box.exe" "$Dir\sing-box.exe" -Force
    $exeChanged = $true
  }
}
foreach ($f in 'geosite-cn.srs', 'geoip-cn.srs') {
  if (-not (Same "$Stage\$f" "$Dir\$f")) { Copy-Item "$Stage\$f" "$Dir\$f" -Force; Say "规则文件 $f 已更新" }
}
& "$Dir\sing-box.exe" check -D $Dir -c "$Stage\config.json"
if ($LASTEXITCODE -ne 0) { throw "新配置没通过 sing-box check，什么都没改" }
$configChanged = -not (Same "$Stage\config.json" "$Dir\config.json")
$backup = $null
if ($configChanged) {
  if (Test-Path "$Dir\config.json") {
    $backup = "$Dir\backups\config-$(Get-Date -Format yyyyMMdd-HHmmss).json"
    Copy-Item "$Dir\config.json" $backup
  }
  Copy-Item "$Stage\config.json" "$Dir\config.json" -Force
  Say "配置已更新（旧的在 backups\）"
} else { Say "配置没有变化" }
# older manual setups left backups next to the config
Get-ChildItem $Dir -Filter 'config.json.bak*' -ErrorAction SilentlyContinue | Move-Item -Destination "$Dir\backups\" -Force
Get-ChildItem $Dir -File | ForEach-Object { icacls $_.FullName /reset | Out-Null }

# ---------------------------------------------------------------- scripts (toggle needs admin; status + tray readable by every user)
Copy-Item "$Stage\vpn-toggle.ps1" "$Dir\vpn-toggle.ps1" -Force
foreach ($f in 'vpn-status.ps1', 'vpn-tray.ps1', 'vpn-tray.vbs') { Copy-Item "$Stage\$f" "$Tools\$f" -Force }
if (-not (Test-Path "$Tools\vpn-switch.log")) { New-Item -ItemType File "$Tools\vpn-switch.log" | Out-Null }
Get-ChildItem $Tools -File | ForEach-Object { icacls $_.FullName /reset | Out-Null }
icacls "$Tools\vpn-switch.log" /grant '*S-1-5-32-545:(M)' | Out-Null     # everyone's toggle/status/tray appends here
icacls "$Dir\vpn-toggle.ps1" /reset | Out-Null

# ---------------------------------------------------------------- 回国 exit: reverse ssh tunnel (SYSTEM, at boot)
if ($CnExit) {
  $cd = "C:\ProgramData\$Slug-cn"
  New-Item -ItemType Directory -Force $cd | Out-Null
  icacls $cd /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  if (-not (Test-Path "$cd\id_ed25519")) {
    # Start-Process keeps the empty -N "" (PowerShell 5.1 drops empty native arguments)
    Start-Process "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -ArgumentList "-q -t ed25519 -N `"`" -C $Slug-cn-tunnel@$env:COMPUTERNAME -f `"$cd\id_ed25519`"" -Wait -NoNewWindow
    Say "回国通道钥匙已生成"
  }
  # OpenSSH refuses a private key anyone but SYSTEM / Administrators can read
  icacls "$cd\id_ed25519" /setowner '*S-1-5-18' | Out-Null
  icacls "$cd\id_ed25519" /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
  # ssh-keygen also gives the creating account its own ACE; to ssh running as SYSTEM that is "someone else",
  # and it refuses the key ("UNPROTECTED PRIVATE KEY FILE"). Keep only SYSTEM and Administrators.
  foreach ($ace in (Get-Acl "$cd\id_ed25519").Access) {
    $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ('S-1-5-18', 'S-1-5-32-544' -notcontains $sid) { icacls "$cd\id_ed25519" /remove:g "*$sid" | Out-Null }
  }
  Copy-Item "$Stage\cn-exit-tunnel.ps1" "$cd\cn-exit-tunnel.ps1" -Force
  icacls "$cd\cn-exit-tunnel.ps1" /reset | Out-Null
  $ta = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cd\cn-exit-tunnel.ps1`" -Server $CnServer -User $CnUser -Port $CnPort"
  $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
  $tp = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName "$Slug-cn-tunnel" -Action $ta -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $ts -Principal $tp -Description '回国出口：ssh 反向通道把本机 SOCKS 挂到服务器' -Force | Out-Null
  Stop-ScheduledTask -TaskName "$Slug-cn-tunnel" -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape("$Slug-cn") } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-ScheduledTask -TaskName "$Slug-cn-tunnel"
  Say "回国通道计划任务 $Slug-cn-tunnel 已启动（日志 $cd\tunnel.log）"
  Write-Output ("CN_EXIT_PUBKEY: " + (Get-Content "$cd\id_ed25519.pub" -Raw).Trim())
}

# ---------------------------------------------------------------- boot task (Windows keeps connecting at boot, as before)
$action = New-ScheduledTaskAction -Execute "$Dir\sing-box.exe" -Argument "run -D `"$Dir`" -c `"$Dir\config.json`"" -WorkingDirectory $Dir
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$existing = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
$disabled = $existing -and $existing.State -eq 'Disabled'
Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "${Slug}: VPN to the home exit server" -Force | Out-Null
if ($disabled) { Disable-ScheduledTask -TaskName $Task | Out-Null }       # keep the user's "不开机自动连接" choice
Say "计划任务 $Task 就绪（开机自动连接：$(-not $disabled)）"

# ---------------------------------------------------------------- desktop user's shortcuts and tray
$acct = Get-CimInstance Win32_UserAccount -Filter "Name='$DesktopUser' AND LocalAccount=True"
if (-not $acct) { throw "找不到本机账号 $DesktopUser" }
$home_ = "C:\Users\$DesktopUser"
$desk = "$home_\Desktop"
$shellKey = "Registry::HKEY_USERS\$($acct.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
if (Test-Path $shellKey) { $desk = ((Get-ItemProperty $shellKey).Desktop) -replace '%USERPROFILE%', $home_ }
elseif (Test-Path "$home_\OneDrive\Desktop") { $desk = "$home_\OneDrive\Desktop" }
$startup = "$home_\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force $startup | Out-Null
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sh = New-Object -ComObject WScript.Shell
function Shortcut($path, $target, $arguments, $icon, $desc, [switch]$Admin) {
  $s = $sh.CreateShortcut($path)
  $s.TargetPath = $target; $s.Arguments = $arguments; $s.IconLocation = $icon; $s.Description = $desc
  $s.WorkingDirectory = Split-Path $target
  $s.Save()
  if ($Admin) { $b = [IO.File]::ReadAllBytes($path); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($path, $b) }
}
Shortcut "$desk\VPN 开关.lnk" $ps "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\vpn-toggle.ps1`"" "$env:SystemRoot\System32\shell32.dll,13" '__EXIT_NAME__出口 VPN 开关（弹窗确认后切换）' -Admin
Shortcut "$desk\VPN 状态.lnk" $ps "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Tools\vpn-status.ps1`"" "$env:SystemRoot\System32\shell32.dll,23" '看 VPN 状态和出口 IP（不需要管理员）'
Shortcut "$startup\VPN 托盘.lnk" "$env:SystemRoot\System32\wscript.exe" "`"$Tools\vpn-tray.vbs`"" "$env:SystemRoot\System32\shell32.dll,13" 'VPN 托盘图标（右下角状态，右键连接/断开）'
Say "桌面图标 → $desk；开机托盘 → Startup"

# (re)start the tray as the desktop user if they are logged on, so it picks up the new script
$loggedOn = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User -eq $DesktopUser }
if ($loggedOn) {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'vpn-tray' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "`"$Tools\vpn-tray.vbs`""
  $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$DesktopUser" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName "$Slug-tray-start" -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskName "$Slug-tray-start"; Start-Sleep 3
  Unregister-ScheduledTask -TaskName "$Slug-tray-start" -Confirm:$false
  Say "托盘已按 $DesktopUser 重新启动"
}

# ---------------------------------------------------------------- apply
$start = $false
if (-not $existing) {
  $start = $true                                   # first install: connect now
} elseif ($wasRunning -and $exeChanged) {
  $start = $true                                   # we had to stop it to replace the binary
} elseif ($wasRunning -and $configChanged) {
  if ($Apply) { $start = $true }
  else { Say "VPN 正在用旧配置运行：下次启动（开机或点「VPN 开关」）时生效；要立即生效加 -Apply" }
} elseif (-not $wasRunning -and ($configChanged -or $exeChanged)) {
  Say "VPN 现在是关着的：没替你打开，新配置下次连接时生效"
}
if ($start) {
  if ($backup) {
    # safety net: if the new config breaks the tunnel, put the old one back and restart in 5 minutes
    $rb = "Copy-Item '$backup' '$Dir\config.json' -Force; Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue; Stop-Process -Name sing-box -Force -ErrorAction SilentlyContinue; Start-Sleep 2; Start-ScheduledTask -TaskName $Task"
    $ra = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -Command `"$rb`""
    Register-ScheduledTask -TaskName "$Slug-rollback" -Action $ra -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)) -Principal $principal -Force | Out-Null
    Say "回滚任务已挂上（$((Get-Date).AddMinutes(5).ToString('HH:mm:ss')) 自动恢复旧配置，验证通过就撤掉）"
  }
  Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
  Stop-Process -Name sing-box -Force -ErrorAction SilentlyContinue
  Start-Sleep 2
  Start-ScheduledTask -TaskName $Task
  Start-Sleep 8
  $ip = $null
  for ($i = 0; $i -lt 5 -and -not $ip; $i++) {
    try { $ip = (curl.exe -s --max-time 10 https://ipinfo.io/json | ConvertFrom-Json).ip } catch { Start-Sleep 3 }
  }
  if ($ServerV4 -and $ip -eq $ServerV4) {
    Unregister-ScheduledTask -TaskName "$Slug-rollback" -Confirm:$false -ErrorAction SilentlyContinue
    Say "已重启，出口 $ip ✓（回滚任务已撤）"
  } else {
    Say "⚠️ 重启后出口是 [$ip]，不是 $ServerV4：回滚任务会在 5 分钟内恢复旧配置"
    exit 2
  }
}
Say "完成"
