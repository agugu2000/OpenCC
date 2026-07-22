#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
中文地区用语转换器 — 基于自编译的 OpenCC 绑定（含 jieba 分词）。

==== 安装方式 ====
将 py_release 内的文件复制到 Mylibs/ 下：
    opencc.dll            OpenCC 动态库（优先使用，含完整 C API）
    opencc_clib.pyd       Python C++ 扩展（备选，DLL 不可用时使用）
    opencc_data.zip       配置、词典、jieba 分词数据（压缩包）

==== 原理 ====
优先通过 ctypes 调用 opencc.dll 的 C API（opencc_inspect_utf8），
获取 JSON 格式的完整转换流水线，对比各阶段 segments 提取替换记录。
如果 DLL 不可用，回退到 import opencc_clib.pyd（pybind11 绑定）。

==== 預設配置文件 ====
s2t.json    Simplified Chinese to Traditional Chinese (OpenCC Standard) / 簡體到OpenCC標準繁體
t2s.json    Traditional Chinese (OpenCC Standard) to Simplified Chinese / OpenCC標準繁體到簡體
s2tw.json   Simplified Chinese to Traditional Chinese (Taiwan Standard) / 簡體到台灣正體
tw2s.json   Traditional Chinese (Taiwan Standard) to Simplified Chinese / 台灣正體到簡體
s2hk.json   Simplified Chinese to Traditional Chinese (Hong Kong variant) / 簡體到香港繁體
hk2s.json   Traditional Chinese (Hong Kong variant) to Simplified Chinese / 香港繁體到簡體
s2twp.json  Simplified Chinese to Traditional Chinese (Taiwan Standard, with Taiwan Phrases) / 簡體到台灣正體（含台灣常用詞彙）
tw2sp.json  Traditional Chinese (Taiwan Standard) to Simplified Chinese (Mainland China Phrases) / 台灣正體到簡體（含中國大陸常用詞彙）
t2tw.json   Traditional Chinese (OpenCC Standard) to Traditional Chinese (Taiwan Standard) / OpenCC標準繁體到台灣正體
tw2t.json   Traditional Chinese (Taiwan Standard) to Traditional Chinese (OpenCC Standard) / 台灣正體到OpenCC標準繁體
t2hk.json   Traditional Chinese (OpenCC Standard) to Traditional Chinese (Hong Kong variant) / OpenCC標準繁體到香港繁體
hk2t.json   Traditional Chinese (Hong Kong variant) to Traditional Chinese (OpenCC Standard) / 香港繁體到OpenCC標準繁體

-- Jieba 分词配置 --
s2t_jieba.json    簡體到OpenCC標準繁體（Jieba分词）
s2tw_jieba.json   簡體到台灣正體（Jieba分词）
s2twp_jieba.json  簡體到台灣正體（Jieba分词，含台灣常用詞彙）
s2hk_jieba.json   簡體到香港繁體（Jieba分词）
s2hkp_jieba.json  簡體到香港繁體（Jieba分词，含香港常用詞彙）
hk2sp_jieba.json  香港繁體到簡體（Jieba分词，含中國大陸常用詞彙）
tw2sp_jieba.json  台灣正體到簡體（Jieba分词，含中國大陸常用詞彙）

-- 開發中 --
s2hkp.json  Simplified Chinese to Traditional Chinese (Hong Kong variant, with Hong Kong Phrases) / 簡體到香港繁體（香港常用詞彙）
hk2sp.json  Traditional Chinese (Hong Kong variant) to Simplified Chinese (Mainland China Phrases) / 香港繁體到簡體（含中國大陸常用詞彙）

-- 僅供探索性研究 --
t2jp.json   Old Japanese Kanji (Kyūjitai) to New Japanese Kanji (Shinjitai) / 日文舊字體到日文新字體
jp2t.json   New Japanese Kanji (Shinjitai) to Old Japanese Kanji (Kyūjitai) / 日文新字體到日文舊字體

==== 使用示例 ====
    from RegionalReplaceCollector import convert_regional, get_regional_replaces, save_regional_replaces

    text, _ = convert_regional('网络打印机和软件的应用', 's2twp_jieba')
"""

import json
import os
import ctypes
from typing import List, Tuple


# ======================== 确定当前模块所在目录 ========================

_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))


# ======================== 加载 OpenCC 后端 ========================

_OpenCC = None          # OpenCC 类（DLL 的 OpenCC_DLL 或 PYD 的 _OpenCC）
_backend_name = None    # 后端名称标识


def _try_load_dll_backend():
    """尝试加载 opencc.dll，成功返回 (OpenCC_DLL 类, "dll")，失败返回 (None, None)"""
    dll_path = os.path.join(_MODULE_DIR, 'opencc.dll')
    if not os.path.isfile(dll_path):
        return None, None

    try:
        os.add_dll_directory(_MODULE_DIR)
    except AttributeError:
        pass

    dll = ctypes.cdll.LoadLibrary(dll_path)

    dll.opencc_open.argtypes = [ctypes.c_char_p]
    dll.opencc_open.restype = ctypes.c_void_p

    dll.opencc_open_with_zip.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p]
    dll.opencc_open_with_zip.restype = ctypes.c_void_p

    dll.opencc_close.argtypes = [ctypes.c_void_p]
    dll.opencc_close.restype = ctypes.c_int

    dll.opencc_convert_utf8.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    dll.opencc_convert_utf8.restype = ctypes.c_void_p

    dll.opencc_convert_utf8_free.argtypes = [ctypes.c_void_p]
    dll.opencc_convert_utf8_free.restype = None

    dll.opencc_inspect_utf8.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    dll.opencc_inspect_utf8.restype = ctypes.c_void_p

    dll.opencc_error.argtypes = []
    dll.opencc_error.restype = ctypes.c_char_p

    _OpenCC_DLL_dll = dll

    class OpenCC_DLL:
        """封装 opencc.dll 的 C API"""
        __slots__ = ('_handle', '_dll')

        def __init__(self, config_path, include_tofu_risk_dictionaries=True, resource_zip=None):
            self._dll = _OpenCC_DLL_dll
            if resource_zip:
                self._handle = self._dll.opencc_open_with_zip(
                    config_path.encode('utf-8'),
                    1 if include_tofu_risk_dictionaries else 0,
                    resource_zip.encode('utf-8')
                )
            else:
                self._handle = self._dll.opencc_open(config_path.encode('utf-8'))

            if self._handle == -1 or self._handle is None or self._handle == 0:
                err = self._dll.opencc_error()
                msg = err.decode('utf-8') if err else 'unknown error'
                raise RuntimeError(f"opencc_open failed: {msg}")

        def convert(self, text):
            data = text.encode('utf-8')
            ptr = self._dll.opencc_convert_utf8(self._handle, data, len(data))
            if ptr is None or ptr == 0:
                err = self._dll.opencc_error()
                msg = err.decode('utf-8') if err else 'unknown error'
                raise RuntimeError(f"convert failed: {msg}")
            out = ctypes.string_at(ptr).decode('utf-8')
            self._dll.opencc_convert_utf8_free(ptr)
            return out

        def inspect(self, text):
            data = text.encode('utf-8')
            ptr = self._dll.opencc_inspect_utf8(self._handle, data, len(data))
            if ptr is None or ptr == 0:
                err = self._dll.opencc_error()
                msg = err.decode('utf-8') if err else 'unknown error'
                raise RuntimeError(f"inspect failed: {msg}")
            out = json.loads(ctypes.string_at(ptr).decode('utf-8'))
            self._dll.opencc_convert_utf8_free(ptr)
            return _wrap_inspect_result(out)

        def close(self):
            if self._handle:
                self._dll.opencc_close(self._handle)
                self._handle = None

        def __del__(self):
            self.close()

    return OpenCC_DLL, "dll"


def _try_load_pyd_backend():
    """尝试加载 opencc_clib.pyd，成功返回 (OpenCC 类, "pyd")，失败返回 (None, None)"""
    try:
        import opencc_clib  # type: ignore
        return opencc_clib._OpenCC, "pyd"
    except ImportError:
        return None, None


def _wrap_inspect_result(d):
    """将 inspect JSON dict 包装成和 PYD 版一致的对象结构"""
    class Stage:
        __slots__ = ('index', 'segments')
        def __init__(self, d):
            self.index = d['index']
            self.segments = d['segments']

    class InspectResult:
        __slots__ = ('output', 'input', 'segments', 'stages', 'pipelineStages')
        def __init__(self, d):
            self.output = d['output']
            self.input = d['input']
            self.segments = d.get('segments', [])
            self.stages = [Stage(s) for s in d.get('stages', [])]
            self.pipelineStages = [_wrap_inspect_result(ps) for ps in d.get('pipelineStages', [])]

    return InspectResult(d)


# ---- 初始化后端（优先 DLL，其次 PYD）----

_OpenCC, _backend_name = _try_load_dll_backend()
if _OpenCC is None:
    _OpenCC, _backend_name = _try_load_pyd_backend()

if _OpenCC is None:
    raise ImportError(
        "找不到 OpenCC 后端。\n"
        f"请在 {_MODULE_DIR} 下放置 opencc.dll 或 opencc_clib.pyd。\n"
        "编译方法：运行 OpenCC 源码目录下的 build_py.cmd"
    )


# ======================== 全局替换收集器 ========================

# 格式: [(src, dst, config), ...]
_regional_collector: List[Tuple[str, str, str]] = []


def _add_replace(src: str, dst: str, config: str):
    """添加一条替换记录，带 config"""
    if src != dst:
        _regional_collector.append((src, dst, config))


def get_regional_replaces() -> List[Tuple[str, str, str]]:
    """获取所有替换记录"""
    return list(_regional_collector)


def save_regional_replaces(filepath: str):
    """按 config 分组保存地区用语替换日志到 JSON 文件"""
    by_config = {}
    for src, dst, cfg in _regional_collector:
        if cfg not in by_config:
            by_config[cfg] = {"字数相等": {}, "字数不等": {}}
        if len(src) == len(dst):
            by_config[cfg]["字数相等"][src] = dst
        else:
            by_config[cfg]["字数不等"][src] = dst

    # 每个 config 查对应的多字映射
    for cfg in by_config:
        char_dict_name = CONFIG_TO_CHAR_DICT.get(cfg, 'STCharacters')
        char_map = MULTI_CHAR_DICT.get(char_dict_name, {})
        multi = {}
        all_keys = set(list(by_config[cfg]["字数相等"].keys()) + list(by_config[cfg]["字数不等"].keys()))
        for src in all_keys:
            for ch in src:
                if ch in char_map and ch not in multi:
                    multi[ch] = char_map[ch]
        by_config[cfg]["多字对应"] = multi

    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(by_config, f, ensure_ascii=False, indent=2)

    total = sum(len(v["字数相等"]) + len(v["字数不等"]) for v in by_config.values())
    print(f"地区用语替换日志已保存: {filepath}")
    print(f"  共 {total} 条替换，涉及 {len(by_config)} 个配置")
    for cfg, data in by_config.items():
        print(f"  [{cfg}] 相等:{len(data['字数相等'])} 不等:{len(data['字数不等'])} 多字:{len(data['多字对应'])}")


# ======================== 核心转换函数 ========================

_zip_path = os.path.join(_MODULE_DIR, 'opencc_data.zip')
_use_zip = os.path.isfile(_zip_path)
_data_dir = os.path.join(_MODULE_DIR, 'opencc_data')
_converters = {}


def _get_converter(config: str):
    """获取或创建 OpenCC 转换器实例（带缓存）"""
    if config not in _converters:
        if _use_zip:
            _converters[config] = _OpenCC(
                f'{config}.json',
                include_tofu_risk_dictionaries=True,
                resource_zip=_zip_path
            )
        else:
            config_path = os.path.join(_data_dir, 'config', f'{config}.json')
            _converters[config] = _OpenCC(config_path)
    return _converters[config]


def convert_regional(text: str, config: str = 's2twp_jieba') -> Tuple[str, List[Tuple[str, str]]]:
    """转换文本并收集地区用语替换记录

    Args:
        text: 要转换的文本
        config: 配置文件名（不含 .json 后缀）

    Returns:
        (转换后的文本, 替换记录列表)
    """
    if not text:
        return text, []

    cc = _get_converter(config)
    result = cc.inspect(text)
    output, logs = result.output, _extract_logs(result)
    if logs:
        for s, d in logs:
            _add_replace(s, d, config)
    return output, logs


def _extract_logs(result) -> List[Tuple[str, str]]:
    """从 inspect 结果中提取替换记录"""
    logs = []
    for ps in result.pipelineStages:
        segments = ps.segments
        stages = ps.stages
        if not stages:
            continue
        for orig, conv in zip(segments, stages[-1].segments):
            if orig != conv:
                logs.append((orig, conv))
    return logs