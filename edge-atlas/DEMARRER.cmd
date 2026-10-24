@echo off
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js est necessaire. Installer la version LTS depuis https://nodejs.org puis relancer.
  pause
  exit /b 1
)
echo Ouvrez http://127.0.0.1:4173/#radar dans votre navigateur.
echo Gardez cette fenetre ouverte pendant la surveillance.
node --use-system-ca server.cjs
pause
