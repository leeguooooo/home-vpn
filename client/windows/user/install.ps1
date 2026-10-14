# __BRAND__ · Windows 安装（给用户自己装的版本）。订阅页上「复制安装命令」得到的就是：
#   powershell -ExecutionPolicy Bypass -c "irm <订阅链接>/windows | iex"
# 订阅服务（sub/worker.js）下发时填好占位符：这个人的订阅链接、sing-box 版本、本目录其它脚本（托盘、自动更新、卸载）
# 的 base64，以及站点的名字（BRAND / APP_ID / EXIT_NAME / EXIT_COUNTRY，来自 site.env，经订阅记录带过来）。重复运行 = 修复 / 升级，不会装出两份。
#
# 装好之后：
#   C:\ProgramData\__APP_ID__\            sing-box.exe、config.json（有密码：只有 SYSTEM / 管理员可读）、日志
#   计划任务 __APP_ID__                   以 SYSTEM 跑 sing-box（虚拟网卡）；开机自动连接；普通用户可以启动 / 停止它
#   计划任务 __APP_ID__-Update            以 SYSTEM 每 6 小时和开机时拉订阅，校验通过才替换配置
#   开始菜单「__BRAND__」、所有用户的启动项「__BRAND__」 → 右下角托盘图标（tray.ps1），点一下就连接 / 断开，不再弹管理员确认
# 和管理员远程装的那套（C:\ProgramData\sing-box、任务 sing-box）互不相干。
function Install-__APP_ID__ {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar makes downloads 10x slower on PowerShell 5
    $SubUrl = '__SUB_URL__'
    $Base = ([Uri]$SubUrl).GetLeftPart('Authority')
    $Dir = 'C:\ProgramData\__APP_ID__'
    $Task = '__APP_ID__'

    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ''
        Write-Host '  安装需要管理员权限：接下来弹出的窗口里请点「是」。' -ForegroundColor Yellow
        Write-Host ''
        $cmd = "irm '$SubUrl/windows' | iex"
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        } catch {
            Write-Host '  没有得到管理员权限，安装取消。想装的话重新运行一次，弹窗时点「是」。' -ForegroundColor Red
        }
        return
    }
    $Host.UI.RawUI.WindowTitle = '__BRAND__ · 安装'
    function Step($t) { Write-Host "  · $t" }
    function Fail($t) {
        Write-Host ''
        Write-Host "  安装没有完成：$t" -ForegroundColor Red
        Write-Host '  把这个窗口截图发给给你链接的人。按回车关闭。'
        [void](Read-Host)
        throw $t
    }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail '这台电脑是 32 位 Windows，不支持。' }
    if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) { Fail '这台电脑是 ARM 处理器，暂不支持。' }
    Write-Host ''
    Write-Host '  正在安装「__BRAND__」，大约需要一分钟……' -ForegroundColor Cyan
    Write-Host ''

    # -------------------------------------------------- folder, only SYSTEM and Administrators (the config carries passwords)
    Step '准备安装目录'
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $Pub = "$Dir\app"   # scripts the tray needs: readable by everyone, writable only by admins
    New-Item -ItemType Directory -Force -Path $Pub | Out-Null
    icacls $Pub /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    $Status = "$Dir\status"   # the updater writes, everyone reads (expired / last update)
    New-Item -ItemType Directory -Force -Path $Status | Out-Null
    icacls $Status /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

    # -------------------------------------------------- scripts shipped inside this installer
    $utf8bom = New-Object Text.UTF8Encoding $true
    $files = @{ __FILES__ }
    foreach ($name in $files.Keys) {
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($files[$name])) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText("$Pub\$name", $text, $utf8bom)
    }
    [IO.File]::WriteAllText("$Dir\sub.txt", $SubUrl, (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText("$Pub\help.txt", $SubUrl, (New-Object Text.UTF8Encoding $false))   # tray「使用说明」opens the install page

    # -------------------------------------------------- sing-box
    $want = '__SINGBOX_VERSION__'
    $have = if (Test-Path "$Dir\sing-box.exe") { (& "$Dir\sing-box.exe" version 2>$null | Select-Object -First 1) -replace '^sing-box version\s*', '' } else { '' }
    if ($have -ne $want) {
        Step "下载核心组件（约 30 MB）"
        $zip = "$env:TEMP\__APP_ID_LC__-sing-box.zip"
        try { Invoke-WebRequest -UseBasicParsing -Uri "$Base/dl/sing-box-windows-amd64.zip" -OutFile $zip } catch { Fail "下载失败（$($_.Exception.Message)）。检查一下网络再运行一次。" }
        $x = "$env:TEMP\__APP_ID_LC__-sing-box"
        Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zip -DestinationPath $x -Force
        $exe = Get-ChildItem $x -Recurse -Filter sing-box.exe | Select-Object -First 1
        if (-not $exe) { Fail '下载的文件不完整。再运行一次。' }
        Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
        Get-Process sing-box -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir\*" } | Stop-Process -Force
        Start-Sleep -Seconds 1
        Copy-Item $exe.FullName "$Dir\sing-box.exe" -Force
        Remove-Item $zip, $x -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------- configuration from the subscription
    Step '获取你的配置'
    $r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Pub\update.ps1" -Install
    if ($LASTEXITCODE -ne 0) { Fail ($r | Select-Object -Last 1) }

    # -------------------------------------------------- tasks
    Step '设置开机自动连接'
    $sb = New-ScheduledTaskAction -Execute "$Dir\sing-box.exe" -Argument "run -D `"$Dir`" -c `"$Dir\config.json`"" -WorkingDirectory $Dir
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -MultipleInstances IgnoreNew
    $sys = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $auto = (Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue)
    $keepOff = $auto -and -not ($auto.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    if ($keepOff) {   # a repair keeps "开机自动连接" as the user set it
        Register-ScheduledTask -TaskName $Task -Action $sb -Settings $set -Principal $sys -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $Task -Action $sb -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $set -Principal $sys -Force | Out-Null
    }
    $up = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Pub\update.ps1`""
    $upTrig = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Hours 6)))
    $upTrig[0].Delay = 'PT2M'
    Register-ScheduledTask -TaskName "$Task-Update" -Action $up -Trigger $upTrig -Settings $set -Principal $sys -Force | Out-Null
    # let every user start / stop the tunnel and trigger an update (no admin prompt from the tray);
    # changing the tasks themselves stays with administrators
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    foreach ($t in $Task, "$Task-Update") {
        $svc.GetFolder('\').GetTask($t).SetSecurityDescriptor('D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)', 0)
    }

    # -------------------------------------------------- tray, Start menu, uninstall entry
    Step '放上托盘图标和开始菜单'
    $vbs = "$Pub\tray.vbs"
    [IO.File]::WriteAllText($vbs, "CreateObject(""WScript.Shell"").Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$Pub\tray.ps1"""""", 0, False`r`n", (New-Object Text.UnicodeEncoding $false, $true))
    $ws = New-Object -ComObject WScript.Shell
    $icon = "$env:SystemRoot\System32\shell32.dll,13"
    foreach ($lnk in "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\__BRAND__.lnk",
                     "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\__BRAND__.lnk") {
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = "$env:SystemRoot\System32\wscript.exe"
        $s.Arguments = "`"$vbs`""
        $s.IconLocation = $icon
        $s.Description = '__BRAND__：右下角托盘图标，点一下连接 / 断开'
        $s.Save()
    }
    $u = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\__APP_ID__'
    New-Item -Path $u -Force | Out-Null
    Set-ItemProperty $u -Name DisplayName -Value '__BRAND__'
    Set-ItemProperty $u -Name Publisher -Value '__BRAND__'
    Set-ItemProperty $u -Name DisplayIcon -Value $icon
    Set-ItemProperty $u -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Pub\uninstall.ps1`""
    Set-ItemProperty $u -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty $u -Name NoRepair -Value 1 -Type DWord

    # -------------------------------------------------- connect now
    Step '连接'
    Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $Task
    $ok = $false
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $ok -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $ip = $null
        try { $ip = (curl.exe -s -m 5 https://ipinfo.io/json | Out-String | ConvertFrom-Json) } catch {}
        $ok = $ip -and ('__EXIT_COUNTRY__' -eq '' -or $ip.country -eq '__EXIT_COUNTRY__')
    }
    # restart the tray as the signed-in (not elevated) user: explorer opens the .vbs in the user's own session
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*__APP_ID__\app\tray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process explorer.exe -ArgumentList "`"$vbs`""

    Write-Host ''
    if ($ok) {
        Write-Host "  装好了，已经连上（出口 $($ip.ip) __EXIT_NAME__）。" -ForegroundColor Green
    } else {
        Write-Host '  装好了，但还没确认连上。稍等半分钟，看右下角托盘图标：绿色 = 已连接。' -ForegroundColor Yellow
    }
    Write-Host '  以后看右下角的圆点图标：绿色 = 已连接，灰色 = 未连接；点一下它就能连接 / 断开。'
    Write-Host '  图标被收起来了的话，点任务栏右下角的「^」就能看到。'
    Write-Host ''
    Write-Host '  按回车关闭这个窗口。'
    [void](Read-Host)
}
Install-__APP_ID__
