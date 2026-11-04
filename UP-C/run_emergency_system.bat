@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "release\应急系统.exe" (
    start "" "release\应急系统.exe"
    exit /b 0
)
if exist ".venv\Scripts\pythonw.exe" (
    start "" ".venv\Scripts\pythonw.exe" "emergency_system.py"
    exit /b 0
)
python -c "import tkinter, serial" >nul 2>&1
if errorlevel 1 (
    echo Python, Tkinter or pyserial is missing.
    echo Run: python -m pip install -r requirements.txt
    pause
    exit /b 1
)
python emergency_system.py
if errorlevel 1 pause
