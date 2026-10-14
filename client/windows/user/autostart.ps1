# __BRAND__ · 开关「开机自动连接」（托盘菜单调用，需要管理员：弹一次确认）。
param([switch]$On, [switch]$Off)
$Task = '__APP_ID__'
$t = Get-ScheduledTask -TaskName $Task -ErrorAction Stop
if ($On) {
    Set-ScheduledTask -TaskName $Task -Trigger (New-ScheduledTaskTrigger -AtStartup) | Out-Null
} elseif ($Off) {
    Set-ScheduledTask -TaskName $Task -Trigger @() -ErrorAction SilentlyContinue | Out-Null
    if ((Get-ScheduledTask -TaskName $Task).Triggers.Count) {   # older PowerShell refuses an empty list: drop it via the task object
        $t = Get-ScheduledTask -TaskName $Task
        $t.Triggers = @()
        Set-ScheduledTask -InputObject $t | Out-Null
    }
}
# keep "every user may start / stop it" (re-registering can reset the permissions)
$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
$svc.GetFolder('\').GetTask($Task).SetSecurityDescriptor('D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)', 0)
