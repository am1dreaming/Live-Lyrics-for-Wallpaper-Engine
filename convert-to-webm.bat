@echo off
rem MinenkoY
where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo ffmpeg not found. Install it first with:
  echo.
  echo    winget install Gyan.FFmpeg
  echo.
  echo ...then re-open a NEW terminal / re-run this script.
  pause
  exit /b 1
)
if "%~1"=="" (
  echo Drag one or more video files onto this .bat to convert them to WebM.
  pause
  exit /b 0
)
:loop
if "%~1"=="" goto done
echo Converting "%~nx1" ...
ffmpeg -y -i "%~1" -c:v libvpx-vp9 -crf 33 -b:v 0 -an "%~dpn1.webm"
shift
goto loop
:done
echo.
echo Done! The .webm files are next to the originals.
echo Pick one in Wallpaper Engine: Background video property.
pause
