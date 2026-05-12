@echo off
REM Clean up all Dune Dashboard CA certificates and reinstall the current one
REM Must be run as Administrator

setlocal
set CERT_PATH=%~dp0ssl\ca.pem

echo ============================================================
echo   Dune Dashboard - CA Certificate Cleanup
echo ============================================================
echo.

if not exist "%CERT_PATH%" (
    echo ERROR: CA certificate not found at %CERT_PATH%
    echo Run setup.bat first to generate the CA certificate.
    pause
    exit /b 1
)

echo Removing all existing Dune Dashboard CA certificates...
echo.

REM Remove from CurrentUser store
powershell -NoProfile -Command "$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser'); $store.Open('ReadWrite'); $certs = $store.Certificates | Where-Object { $_.Subject -like '*Dune Dashboard*' }; Write-Host \"Found $($certs.Count) in CurrentUser\"; foreach ($c in $certs) { $store.Remove($c); Write-Host \"  Removed: $($c.Thumbprint)\" }; $store.Close()"

REM Remove from LocalMachine store
powershell -NoProfile -Command "$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine'); $store.Open('ReadWrite'); $certs = $store.Certificates | Where-Object { $_.Subject -like '*Dune Dashboard*' }; Write-Host \"Found $($certs.Count) in LocalMachine\"; foreach ($c in $certs) { $store.Remove($c); Write-Host \"  Removed: $($c.Thumbprint)\" }; $store.Close()"

echo.
echo Installing fresh CA certificate...
echo.

certutil -addstore -f "Root" "%CERT_PATH%"

if %errorlevel% equ 0 (
    echo.
    echo SUCCESS: CA certificate cleaned and reinstalled.
    echo Restart your browser for the change to take effect.
) else (
    echo.
    echo FAILED: Could not install certificate.
    echo Make sure you are running this script as Administrator.
)

echo.
pause
