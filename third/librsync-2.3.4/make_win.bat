@echo off
setlocal

REM Default build type
set "BUILD_TYPE=Debug"

REM Check command-line argument
if "%1"=="" (
    echo Usage: %0 [debug^|release]
    echo Defaulting to Debug
) else if /I "%1"=="release" (
    set "BUILD_TYPE=Release"
) else if /I not "%1"=="debug" (
    echo Error: Invalid build type "%1". Use "debug" or "release".
    exit /b 1
)

REM Set build directory
set "BUILD_DIR=_build_win_%BUILD_TYPE%"

REM Create build directory
if not exist "%BUILD_DIR%\" (
    mkdir "%BUILD_DIR%" || (
        echo Error: Failed to create directory "%BUILD_DIR%".
        exit /b 1
    )
)

REM Change to build directory
cd /d "%BUILD_DIR%" || (
    echo Error: Failed to change to directory "%BUILD_DIR%".
    exit /b 1
)

REM Check if CMake is installed
where cmake >nul 2>&1 || (
    echo Error: CMake is not installed or not in PATH.
    exit /b 1
)

REM Run CMake
cmake -DCMAKE_BUILD_TYPE="%BUILD_TYPE%" -DBUILD_SHARED_LIBS=OFF .. || (
    echo Error: CMake configuration failed.
    exit /b 1
)

echo CMake configured successfully in %BUILD_DIR%
exit /b 0