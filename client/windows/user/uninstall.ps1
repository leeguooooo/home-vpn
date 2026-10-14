# __BRAND__ · 卸载（托盘「卸载__BRAND__…」或「设置 → 应用」里卸载；需要管理员）。
# 停掉并删除计划任务、托盘、快捷方式、卸载项和 C:\ProgramData\__APP_ID__。-Yes：不弹窗（远程维护用）。
param([switch]$Yes)
Add-Type -AssemblyName System.Windows.Forms
$ok = if ($Yes) { 'Yes' } else { [System.Windows.Forms.MessageBox]::Show("确定要卸载「__BRAND__」吗？`n`n卸载后这台电脑就不走__BRAND__了；以后想用，用订阅页上的安装命令再装一次。", '卸载__BRAND__', 'YesNo', 'Question') }
if ($ok -ne 'Yes') { exit }
$Dir = 'C:\ProgramData\__APP_ID__'
foreach ($t in '__APP_ID__', '__APP_ID__-Update') {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Get-Process sing-box -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*__APP_ID__\app\tray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\__BRAND__.lnk",
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\__BRAND__.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\__APP_ID__' -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
# this script lives in the folder being removed: finish from a copy in TEMP
$me = "$env:TEMP\__APP_ID_LC__-remove.cmd"
Set-Content -Path $me -Encoding ASCII -Value "@echo off`r`nping -n 3 127.0.0.1 >nul`r`nrmdir /s /q `"$Dir`"`r`ndel `"%~f0`""
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c `"$me`""
if (-not $Yes) { [void][System.Windows.Forms.MessageBox]::Show('已卸载。', '__BRAND__', 'OK', 'Information') }
