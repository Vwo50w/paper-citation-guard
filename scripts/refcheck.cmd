@echo off
rem paper-citation-guard 的 Windows 入口：优先 Python，其次 PowerShell
setlocal
where python >nul 2>nul && goto :py
where pwsh   >nul 2>nul && goto :ps
echo 需要 Python 3 或 PowerShell 7，两个都没找到。
echo   Python: winget install Python.Python.3.12
echo   PowerShell: winget install Microsoft.PowerShell
exit /b 127

:py
python "%~dp0refcheck.py" %*
exit /b %ERRORLEVEL%

:ps
pwsh -NoProfile -File "%~dp0refcheck.ps1" %*
exit /b %ERRORLEVEL%