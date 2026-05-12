@echo off
REM Install Dune Dashboard CA certificate into Windows Trusted Root CA store
REM Must be run as Administrator

setlocal
set CERT_PATH=%~dp0ssl\ca.pem

if not exist "%CERT_PATH%" (
    echo ERROR: CA certificate not found at %CERT_PATH%
    echo Run setup.bat first to generate the CA certificate.
    pause
    exit /b 1
)

echo Installing Dune Dashboard CA certificate...
echo.

certutil -addstore -f "Root" "%CERT_PATH%"

if %errorlevel% equ 0 (
    echo.
    echo SUCCESS: CA certificate installed to Trusted Root Certification Authorities.
    echo Browser warnings for https://localhost:5050 should now be gone.
    echo.
    echo Restart your browser for the change to take effect.
) else (
    echo.
    echo FAILED: Could not install certificate.
    echo Make sure you are running this script as Administrator.
)

echo.
pause
