@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ==================== pre0. 检测 7-Zip ====================
set USE_7Z=0
if exist "C:\Program Files\7-Zip\7z.exe" (
    set USE_7Z=1
    set "ZIP_CMD=C:\Program Files\7-Zip\7z.exe"
) else if exist "C:\Program Files (x86)\7-Zip\7z.exe" (
    set USE_7Z=1
    set "ZIP_CMD=C:\Program Files (x86)\7-Zip\7z.exe"
) else (
    echo [提示] 未找到 7-Zip，将使用 Python 打包
)

:: ==================== pre1. 参数处理 ====================
if "%~1"=="clean" (
    if exist "%~dp0build" rmdir /s /q "%~dp0build"
    echo 已清理 build 目录
    pause
    exit /b 0
)

set BUILD_TYPE=%~1
if "%BUILD_TYPE%"=="" set BUILD_TYPE=dll
if not "%BUILD_TYPE%"=="pyd" if not "%BUILD_TYPE%"=="dll" if not "%BUILD_TYPE%"=="noembed" (
    echo 用法: build_py.cmd [pyd^|dll^|noembed^|clean]
    echo   pyd       - 编译静态 opencc_clib.pyd (含内嵌数据^)
    echo   dll       - 编译 opencc.dll (含内嵌数据^)
    echo   noembed   - 编译 DLL + PYD (不含内嵌数据, 需外部 opencc_data.zip^)
    echo   clean     - 清理 build 目录
    pause
    exit /b 1
)

set SRC_DIR=%~dp0
if "%SRC_DIR:~-1%"=="\" set SRC_DIR=%SRC_DIR:~0,-1%
set BUILD_DIR=%SRC_DIR%\build
set OUT_DIR=%BUILD_DIR%\py_release

:: ==================== pre2. 清除上次的内嵌头文件 ====================
if exist "%BUILD_DIR%\data\generated_embedded.h" del /f /q "%BUILD_DIR%\data\generated_embedded.h"

:: ==================== pre3. 生成拼音词典 TXT ====================
echo.
echo ===== 生成拼音词典 TXT =====
set PINYIN_DIR=%BUILD_DIR%\data
if not exist "%PINYIN_DIR%" mkdir "%PINYIN_DIR%"

python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" dict --input "%SRC_DIR%\data\dictionary\zdic.txt" --output "%PINYIN_DIR%\pinyin.txt"
python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" phrase --phrase "%SRC_DIR%\data\dictionary\large_pinyin.txt" --pinyin "%PINYIN_DIR%\pinyin.txt" --output "%PINYIN_DIR%\phrase_pinyin.txt"
python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" init_letter --input "%PINYIN_DIR%\pinyin.txt" --output "%PINYIN_DIR%\pinyin_init_letter.txt"
python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" init_letter --input "%SRC_DIR%\data\dictionary\large_pinyin.txt" --pinyin "%PINYIN_DIR%\pinyin.txt" --output "%PINYIN_DIR%\phrase_init_letter.txt"
python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" strip_tone --input "%PINYIN_DIR%\pinyin.txt" --output "%PINYIN_DIR%\pinyin_notone.txt"
python "%SRC_DIR%\python\opencc\gen_pinyin_dicts.py" strip_tone --input "%PINYIN_DIR%\phrase_pinyin.txt" --output "%PINYIN_DIR%\phrase_notone.txt"
if errorlevel 1 (
    echo 生成拼音词典失败！
    pause
    exit /b 1
)

:: ==================== 无内嵌模式 ====================
if "%BUILD_TYPE%"=="noembed" goto :compile_noembed

:: ==================== 1. 第一次编译 (不带内嵌) ====================
echo.
if "%BUILD_TYPE%"=="pyd" (
    echo ===== 第一阶段: 编译 OpenCC PYD (不带内嵌数据) =====
    set CMAKE_EXTRA=-DBUILD_SHARED_LIBS=OFF -DBUILD_PYTHON=ON
) else (
    echo ===== 第一阶段: 编译 OpenCC DLL (不带内嵌数据) =====
    set CMAKE_EXTRA=-DBUILD_SHARED_LIBS=ON -DBUILD_PYTHON=OFF
)

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" !CMAKE_EXTRA! ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
    -DCMAKE_CXX_FLAGS="/utf-8 /EHsc /wd4267 /wd4100 /wd4251 /wd4530 /wd4702" ^
    -DCMAKE_C_FLAGS="/utf-8" ^
    -DENABLE_GTEST=OFF ^
    -DENABLE_BENCHMARK=OFF ^
    -DBUILD_OPENCC_JIEBA_PLUGIN=ON ^
    -DOPENCC_EMBED_ASSETS=OFF
if errorlevel 1 (
    echo CMake 配置失败！
    pause
    exit /b 1
)

cmake --build "%BUILD_DIR%" --config Release -- /m /p:UseMultiToolTask=true
if errorlevel 1 (
    echo 第一阶段编译失败！
    pause
    exit /b 1
)

echo.
echo ===== 第一阶段编译完成 =====

:: ==================== 2. 生成拼音 OCD2 ====================
echo.
echo ===== 生成拼音 OCD2 =====
for %%f in (pinyin phrase_pinyin pinyin_init_letter phrase_init_letter pinyin_notone phrase_notone) do (
    "%BUILD_DIR%\src\tools\Release\opencc_dict.exe" --input "%PINYIN_DIR%\%%f.txt" --output "%PINYIN_DIR%\%%f.ocd2" --from text --to ocd2
)

:: ==================== 3. 清理旧目录 ====================
if exist "%OUT_DIR%" rmdir /s /q "%OUT_DIR%"
mkdir "%OUT_DIR%"

:: ==================== 4. 打包 opencc_data.zip (内嵌用, 不含拼音/idf/stop_words) ====================
echo.
echo ===== 打包 opencc_data.zip (内嵌用) =====
set ZIP_TMP=%BUILD_DIR%\zip_tmp
if exist "%ZIP_TMP%" rmdir /s /q "%ZIP_TMP%"
mkdir "%ZIP_TMP%"
mkdir "%ZIP_TMP%\jieba_dict"

:: 繁简 JSON (排除拼音)
for %%f in ("%SRC_DIR%\data\config\*.json") do (
    echo %%f | findstr /i "c2pinyin" >nul
    if errorlevel 1 copy "%%f" "%ZIP_TMP%\" >nul
)
for %%f in ("%SRC_DIR%\plugins\jieba\data\config\*.json") do (
    echo %%f | findstr /i "c2pinyin" >nul
    if errorlevel 1 copy "%%f" "%ZIP_TMP%\" >nul
)
:: 繁简 OCD2 (排除拼音)
for %%f in ("%BUILD_DIR%\data\*.ocd2") do (
    echo %%f | findstr /i "pinyin notone init_letter" >nul
    if errorlevel 1 copy "%%f" "%ZIP_TMP%\" >nul
)
:: Jieba 核心
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\hmm_model.utf8" "%ZIP_TMP%\jieba_dict\" >nul
if exist "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" (
    copy "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" "%ZIP_TMP%\jieba_dict\" >nul
)

if exist "%OUT_DIR%\opencc_data.zip" del /f /q "%OUT_DIR%\opencc_data.zip"
call :pack_zip "%ZIP_TMP%" "%OUT_DIR%\opencc_data.zip"
if exist "%OUT_DIR%\opencc_data.zip" (
    rmdir /s /q "%ZIP_TMP%"
    echo 已生成 opencc_data.zip
) else (
    echo 打包失败！
    pause
    exit /b 1
)

:: ==================== 5. 生成内嵌头文件 ====================
echo.
echo ===== 生成内嵌资源头文件 =====
python "%SRC_DIR%\scripts\pack_assets.py" embed "%OUT_DIR%\opencc_data.zip" "%BUILD_DIR%\data\generated_embedded.h"
if errorlevel 1 (
    echo 生成内嵌头文件失败！
    pause
    exit /b 1
)
echo 已生成 generated_embedded.h

:: ==================== 5.5. 生成多音字映射头文件 ====================
echo.
echo ===== 生成多音字映射头文件 =====
python "%SRC_DIR%\python\opencc\build_multi_char_dict.py" "%SRC_DIR%\data\dictionary" "%BUILD_DIR%\data\multi_char_dict.inc"
if errorlevel 1 (
    echo 生成多音字映射失败！
    pause
    exit /b 1
)
echo 已生成 multi_char_dict.inc

:: ==================== 6. 第二次编译 (带内嵌) ====================
echo.
echo ===== 第二阶段: 重新编译 OpenCC (嵌入数据) =====

:: 强制重新编译
del /s /q "%BUILD_DIR%\src\*.obj" >nul 2>&1

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" !CMAKE_EXTRA! ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
    -DCMAKE_CXX_FLAGS="/utf-8 /EHsc /wd4267 /wd4100 /wd4251 /wd4530 /wd4702" ^
    -DCMAKE_C_FLAGS="/utf-8" ^
    -DENABLE_GTEST=OFF ^
    -DENABLE_BENCHMARK=OFF ^
    -DBUILD_OPENCC_JIEBA_PLUGIN=OFF ^
    -DOPENCC_EMBED_ASSETS=ON
if errorlevel 1 (
    echo CMake 配置失败！
    pause
    exit /b 1
)

cmake --build "%BUILD_DIR%" --config Release -- /m /p:UseMultiToolTask=true
if errorlevel 1 (
    echo 第二阶段编译失败！
    pause
    exit /b 1
)

echo.
echo ===== 编译完成 =====

goto :after_compile

:: ==================== 无内嵌模式编译 ====================
:compile_noembed
echo.
echo ===== 生成多音字映射头文件 =====
python "%SRC_DIR%\python\opencc\build_multi_char_dict.py" "%SRC_DIR%\data\dictionary" "%BUILD_DIR%\data\multi_char_dict.inc"
if errorlevel 1 (
    echo 生成多音字映射失败！
    pause
    exit /b 1
)
echo 已生成 multi_char_dict.inc

echo.
echo ===== 编译 OpenCC (不含内嵌数据) =====

cmake -S "%SRC_DIR%" -B "%BUILD_DIR%" ^
    -DBUILD_SHARED_LIBS=ON ^
    -DBUILD_PYTHON=ON ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
    -DCMAKE_CXX_FLAGS="/utf-8 /EHsc /wd4267 /wd4100 /wd4251 /wd4530 /wd4702" ^
    -DCMAKE_C_FLAGS="/utf-8" ^
    -DENABLE_GTEST=OFF ^
    -DENABLE_BENCHMARK=OFF ^
    -DBUILD_OPENCC_JIEBA_PLUGIN=ON ^
    -DOPENCC_EMBED_ASSETS=OFF
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

:: ==================== 无内嵌模式生成拼音 OCD2 ====================
echo.
echo ===== 生成拼音 OCD2 =====
for %%f in (pinyin phrase_pinyin pinyin_init_letter phrase_init_letter pinyin_notone phrase_notone) do (
    "%BUILD_DIR%\src\tools\Release\opencc_dict.exe" --input "%PINYIN_DIR%\%%f.txt" --output "%PINYIN_DIR%\%%f.ocd2" --from text --to ocd2
)

:: ==================== 输出 ====================
:after_compile
:: ==================== 7. 清理旧目录 ====================
if exist "%OUT_DIR%" rmdir /s /q "%OUT_DIR%"
mkdir "%OUT_DIR%"


:: ==================== 8. 复制 .pyd (仅 PYD/NOEMBED 模式) ====================
if "%BUILD_TYPE%"=="pyd" goto :copy_pyd
if "%BUILD_TYPE%"=="noembed" goto :copy_pyd
goto :copy_dll

:copy_pyd
echo.
echo ===== 复制 opencc_clib.pyd =====
for %%f in ("%BUILD_DIR%\Release\opencc_clib*.pyd") do (
    copy "%%f" "%OUT_DIR%\opencc_clib.pyd" >nul
    echo %%f -^> opencc_clib.pyd
)
if "%BUILD_TYPE%"=="pyd" goto :after_copy

:copy_dll
:: ==================== 9. 复制 opencc.dll (仅 DLL/NOEMBED 模式) ====================
echo.
echo ===== 复制输出 =====
copy "%SRC_DIR%\python\opencc\RegionalReplacer.py" "%OUT_DIR%\" >nul
if exist "%BUILD_DIR%\src\Release\opencc.dll" (
    copy "%BUILD_DIR%\src\Release\opencc.dll" "%OUT_DIR%\" >nul
) else if exist "%BUILD_DIR%\src\tools\Release\opencc.dll" (
    copy "%BUILD_DIR%\src\tools\Release\opencc.dll" "%OUT_DIR%\" >nul
) else (
    echo 错误: 找不到 opencc.dll！
    pause
    exit /b 1
)

:after_copy
if "%BUILD_TYPE%"=="noembed" goto :zip_full

:: ==================== 10. 打包 opencc_data.zip (内嵌版外部用, 拼音 + idf + stop_words) ====================
echo.
echo ===== 打包 opencc_data.zip (外部用, 拼音+idf+stop_words) =====
set ZIP_TMP=%BUILD_DIR%\zip_tmp
if exist "%ZIP_TMP%" rmdir /s /q "%ZIP_TMP%"
mkdir "%ZIP_TMP%"
mkdir "%ZIP_TMP%\jieba_dict"

:: 拼音 JSON
copy "%SRC_DIR%\data\config\c2pinyin*.json" "%ZIP_TMP%\" >nul
copy "%SRC_DIR%\plugins\jieba\data\config\c2pinyin*.json" "%ZIP_TMP%\" >nul
:: 拼音 OCD2
copy "%BUILD_DIR%\data\*pinyin*.ocd2" "%ZIP_TMP%\" >nul
copy "%BUILD_DIR%\data\*notone*.ocd2" "%ZIP_TMP%\" >nul
copy "%BUILD_DIR%\data\*init_letter*.ocd2" "%ZIP_TMP%\" >nul
:: Jieba 可选文件
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\idf.utf8" "%ZIP_TMP%\jieba_dict\" >nul
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\stop_words.utf8" "%ZIP_TMP%\jieba_dict\" >nul

if exist "%OUT_DIR%\opencc_data.zip" del /f /q "%OUT_DIR%\opencc_data.zip"
call :pack_zip "%ZIP_TMP%" "%OUT_DIR%\opencc_data.zip"
if exist "%OUT_DIR%\opencc_data.zip" (
    rmdir /s /q "%ZIP_TMP%"
    echo 已生成 opencc_data.zip (放 DLL 同目录可补充拼音数据^)
) else (
    echo 打包失败！
    pause
    exit /b 1
)
goto :end

:: ==================== 10b. 打包 opencc_data.zip (非内嵌版, 全量) ====================
:zip_full
echo.
echo ===== 打包 opencc_data.zip (外部用, 全量) =====
set ZIP_TMP=%BUILD_DIR%\zip_tmp
if exist "%ZIP_TMP%" rmdir /s /q "%ZIP_TMP%"
mkdir "%ZIP_TMP%"
mkdir "%ZIP_TMP%\jieba_dict"

copy "%SRC_DIR%\data\config\*.json" "%ZIP_TMP%\" >nul
copy "%SRC_DIR%\plugins\jieba\data\config\*.json" "%ZIP_TMP%\" >nul
copy "%BUILD_DIR%\data\*.ocd2" "%ZIP_TMP%\" >nul
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\hmm_model.utf8" "%ZIP_TMP%\jieba_dict\" >nul
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\idf.utf8" "%ZIP_TMP%\jieba_dict\" >nul
copy "%SRC_DIR%\plugins\jieba\deps\cppjieba\dict\stop_words.utf8" "%ZIP_TMP%\jieba_dict\" >nul
if exist "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" (
    copy "%BUILD_DIR%\plugins\jieba\Release\jieba_dict\jieba_merged.ocd2" "%ZIP_TMP%\jieba_dict\" >nul
)

if exist "%OUT_DIR%\opencc_data.zip" del /f /q "%OUT_DIR%\opencc_data.zip"
call :pack_zip "%ZIP_TMP%" "%OUT_DIR%\opencc_data.zip"
if exist "%OUT_DIR%\opencc_data.zip" (
    rmdir /s /q "%ZIP_TMP%"
    echo 已生成 opencc_data.zip (放 DLL 同目录可覆盖内嵌数据^)
) else (
    echo 打包失败！
    pause
    exit /b 1
)

:: ==================== 11. 清理编译进程 ====================
:end
echo.
echo ===== 清理编译进程 =====
taskkill /f /im cl.exe 2>nul
taskkill /f /im vctip.exe 2>nul
taskkill /f /im msbuild.exe 2>nul
timeout /t 2 /nobreak >nul

:: ==================== 12. 完成 ====================
echo.
echo ===== 完成！ =====
echo 模式: %BUILD_TYPE%
if not "%BUILD_TYPE%"=="noembed" echo 内嵌数据: 已编译进 DLL/PYD (繁简核心^)
if "%BUILD_TYPE%"=="noembed" echo 内嵌数据: 未内嵌, 需外部 opencc_data.zip
echo 外部 ZIP: opencc_data.zip
echo 输出目录: %OUT_DIR%
echo.
dir "%OUT_DIR%" /b
pause
exit /b 0

:: ============================================================
:: 子程序: 打包 ZIP，优先用 7z，失败则用 Python
:: 参数: %1 = 源目录, %2 = 输出 zip 文件路径
:: ============================================================
:pack_zip
set "PACK_SRC=%~1"
set "PACK_DST=%~2"

if %USE_7Z%==1 (
    echo [7-Zip] 压缩中...
    "%ZIP_CMD%" a -tzip -mx=9 -r "%PACK_DST%" "%PACK_SRC%\*" >nul 2>&1
    if not errorlevel 1 (
        echo [7-Zip] 压缩成功
        exit /b 0
    ) else (
        echo [7-Zip] 压缩失败，降级使用 Python...
    )
)

echo [Python] 使用 pack_assets.py 压缩...
python "%SRC_DIR%\scripts\pack_assets.py" pack "%PACK_SRC%" "%PACK_DST%"
exit /b %errorlevel%