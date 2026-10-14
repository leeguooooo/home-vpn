# 回国出口的反向通道：把本机 sing-box 只接本机的 SOCKS 入口（127.0.0.1:Port）挂到服务器的 127.0.0.1:Port。
# 计划任务 <SLUG>-cn-tunnel 以 SYSTEM 开机运行（client/windows/install.ps1 -CnExit 安装）。断了 10 秒后重连。
# 服务器那头的强制命令（server/cn-exit-session.sh）会清掉上次掉线残留的旧通道。
param([Parameter(Mandatory = $true)][string]$Server,
      [Parameter(Mandatory = $true)][string]$User,
      [Parameter(Mandatory = $true)][int]$Port)
$d = 'C:\ProgramData\__SLUG__-cn'
$log = "$d\tunnel.log"
$ssh = "$env:SystemRoot\System32\OpenSSH\ssh.exe"
function Log($m) {
  if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $log -Encoding UTF8
}
while ($true) {
  Log "connect $User@$Server -R 127.0.0.1:${Port}"
  # no -N: the server's forced command keeps the session and cleans up stale tunnels
  & $ssh -T -i "$d\id_ed25519" -o BatchMode=yes -o ExitOnForwardFailure=yes `
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=20 `
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$d\known_hosts" `
    -R "127.0.0.1:${Port}:127.0.0.1:${Port}" "$User@$Server" 2>> $log
  Log "ssh exited ($LASTEXITCODE), retry in 10 s"
  Start-Sleep -Seconds 10
}
