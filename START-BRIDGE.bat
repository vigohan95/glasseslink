@echo off
title Glasses Bridge
set PY=C:\Users\lokla\AppData\Local\Programs\Python\Python311\python.exe
set ROOT=C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2
set ADB=%ROOT%\tools\platform-tools\adb.exe
set TMP=%ROOT%\tools\tmp
set TEMP=%ROOT%\tools\tmp
if not exist "%TMP%" mkdir "%TMP%"
echo [1/3] adb forward tcp:7333 ...
"%ADB%" forward tcp:7333 tcp:7333 >nul 2>&1
echo [2/3] checking phone ...
"%ADB%" devices | findstr /R "device$" >nul
if errorlevel 1 echo    [WARN] no phone on adb; photo import will fail, status still works.
echo [3/3] starting bridge on port 8787 ...
echo    iPhone Safari: http://192.168.3.90:8787/
echo.
"%PY%" -P "%ROOT%\bridge\server.py" --port 8787
echo.
echo bridge stopped. press any key to close.
pause
