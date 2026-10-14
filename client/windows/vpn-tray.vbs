REM Silently start the VPN tray icon (no console flash at logon).
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\sing-box-tools\vpn-tray.ps1""", 0, False
