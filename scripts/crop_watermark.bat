@echo off
if "%~1"=="" (
  echo Drag a folder onto this icon.
  pause
  exit /b 1
)
python "%~dp0crop_watermark.py" "%~1"
pause
