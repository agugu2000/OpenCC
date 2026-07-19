@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ==================== 0. 参数处理 ====================
if "%~1"=="clean" (
    if exist "%~dp0build" rmdir /s /q "%~dp0build"
    echo 已清理 build 目录
    pause
    exit /b 0
)

set BUILD_TYPE=%~1
if "%BUILD_TYPE%"=="" set BUILD_TYPE=pyd
if not "%BUILD_TYPE%"=="pyd" if not "%BUILD_TYPE%"=="dll" (
    echo 用法: build_py.cmd [pyd^|dll^|clean]
    echo   pyd  - 编译静态 opencc_clib.pyd（无需 opencc.dll）
    echo   dll  - 编译 opencc.dll（DLL 版）
    echo   clean - 清理 build 目录
    pause
    exit /b 1
)

set SRC_DIR=%~dp0
if "%SRC_DIR:~-1%"=="\" set SRC_DIR=%SRC_DIR:~0,-1%
set BUILD_DIR=%SRC_DIR%\build
set OUT_DIR=%BUILD_DIR%\py_release

:: ==================== 1. 编译 ====================
echo.
if "%BUILD_TYPE%"=="pyd" (
    echo ===== 编译 OpenCC PYD（静态链接 + 体积优化）=====
    set CMAKE_EXTRA=-DBUILD_SHARED_LIBS=OFF -DBUILD_PYTHON=ON
) else (
    echo ===== 编译 OpenCC DLL（静态链接 + 体积优化）=====
    set CMAKE_EXTRA=-DBUILD_SHARED_LIBS=ON -DBUILD_PYTHON=OFF
)

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" !CMAKE_EXTRA! ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
    -DCMAKE_CXX_FLAGS="/utf-8" ^
    -DCMAKE_C_FLAGS="/utf-8" ^
    -DENABLE_GTEST=OFF ^
    -DENABLE_BENCHMARK=OFF ^
    -DBUILD_OPENCC_JIEBA_PLUGIN=OFF
if errorlevel 1 (
    echo CMake 配置失败！
    pause
    exit /b 1
)

cmake --build "%BUILD_DIR%" --config Release -- /m /p:UseMultiToolTask=true
if errorlevel 1 (
    echo 编译失败！
    pause
    exit /b 1
)

echo.
echo ===== 编译完成 =====

:: ==================== 2. 清理旧目录 ====================
if exist "%OUT_DIR%" rmdir /s /q "%OUT_DIR%"
mkdir "%OUT_DIR%"

:: ==================== 3. 创建 ZIP 临时目录 ====================
set ZIP_TMP=%BUILD_DIR%\zip_tmp
if exist "%ZIP_TMP%" rmdir /s /q "%ZIP_TMP%"
mkdir "%ZIP_TMP%"
mkdir "%ZIP_TMP%\jieba_dict"

:: ==================== 4. 复制 .pyd（仅 PYD 模式）====================
if "%BUILD_TYPE%"=="pyd" (
    echo.
    echo ===== 复制 .pyd 和调用PY =====
	copy "%SRC_DIR%\python\opencc\RegionalReplacer.py" "%OUT_DIR%\"
    for %%f in ("%BUILD_DIR%\Release\opencc_clib*.pyd") do (
        copy "%%f" "%OUT_DIR%\opencc_clib.pyd"
        echo %%f -^> opencc_clib.pyd
    )
)

:: ==================== 5. 复制 opencc.dll（仅 DLL 模式）====================
if "%BUILD_TYPE%"=="dll" (
    echo.
    echo ===== 复制 opencc.dll 和调用PY =====
	copy "%SRC_DIR%\python\opencc\RegionalReplacer.py" "%OUT_DIR%\"
    if exist "%BUILD_DIR%\src\Release\opencc.dll" (
        copy "%BUILD_DIR%\src\Release\opencc.dll" "%OUT_DIR%\"
    ) else if exist "%BUILD_DIR%\src\tools\Release\opencc.dll" (
        copy "%BUILD_DIR%\src\tools\Release\opencc.dll" "%OUT_DIR%\"
    ) else (
        echo 错误: 找不到 opencc.dll！
        pause
        exit /b 1
    )
)

:: ==================== 6. 复制文件到 ZIP 临时目录 ====================
echo.
echo ===== 准备 ZIP 打包 =====
copy "%SRC_DIR%\data\config\*.json" "%ZIP_TMP%\"
copy "%SRC_DIR%\plugins\jieba\data\config\*.json" "%ZIP_TMP%\"
copy "%BUILD_DIR%\data\*.ocd2" "%ZIP_TMP%\"
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\*.utf8" "%ZIP_TMP%\jieba_dict\"
if exist "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" (
    copy "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" "%ZIP_TMP%\jieba_dict\"
)

:: ==================== 7. 打包 opencc_data.zip ====================
echo.
echo ===== 打包 opencc_data.zip =====
if exist "%OUT_DIR%\opencc_data.zip" del /f /q "%OUT_DIR%\opencc_data.zip"
python -c "import zipfile,os; root=r'%ZIP_TMP%'; z=zipfile.ZipFile(r'%OUT_DIR%\opencc_data.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9); [z.write(os.path.join(r,f),os.path.relpath(os.path.join(r,f),root)) for r,_,fs in os.walk(root) for f in fs]; z.close()"
if exist "%OUT_DIR%\opencc_data.zip" (
    rmdir /s /q "%ZIP_TMP%"
    echo 已生成 opencc_data.zip
) else (
    echo 打包失败！
    pause
    exit /b 1
)

:: ==================== 8. 清理编译进程 ====================
echo.
echo ===== 清理编译进程 =====
taskkill /f /im cl.exe 2>nul
taskkill /f /im vctip.exe 2>nul
taskkill /f /im msbuild.exe 2>nul
timeout /t 2 /nobreak >nul

:: ==================== 9. 完成 ====================
echo.
echo ===== 完成！ =====
echo 模式: %BUILD_TYPE%
echo 输出目录: %OUT_DIR%
echo.
dir "%OUT_DIR%" /b
pause