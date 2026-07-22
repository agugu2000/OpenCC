#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
编译期脚本：从 data/dictionary/*.txt 中提取所有 1 对多字的映射，
追加写入 RegionalReplacer.py 模板，输出到编译目录。
"""

import os
import sys
import json

def build_multi_char_dict(dict_dir: str) -> dict:
    """对齐 Lexicon::ParseKeyValues 的解析逻辑"""
    result = {}
    if not os.path.isdir(dict_dir):
        print(f"警告: 字典目录不存在: {dict_dir}")
        return result

    for filename in sorted(os.listdir(dict_dir)):
        if not filename.endswith('.txt'):
            continue

        filepath = os.path.join(dict_dir, filename)
        dict_name = filename[:-4]
        temp_map = {}

        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                # TAB 分割 key 和 values
                tab_pos = line.find('\t')
                if tab_pos == -1:
                    continue
                key = line[:tab_pos]
                values_str = line[tab_pos + 1:]

                # 空格分割多个 values
                values = values_str.split(' ')
                values = [v for v in values if v]  # 去空

                if key not in temp_map:
                    temp_map[key] = []
                for v in values:
                    if v not in temp_map[key]:
                        temp_map[key].append(v)

        # 只保留有多个目标值的
        char_map = {k: v for k, v in temp_map.items() if len(v) >= 2}
        result[dict_name] = char_map

        if char_map:
            print(f"  {filename}: {len(char_map)} 个多字映射")
        else:
            print(f"  {filename}: (无多字映射)")

    return result

def format_dict_compact(d: dict) -> str:
    """格式化为紧凑格式，每个 key 单独一行（递归）"""
    if not d:
        return "{}"
    lines = ["{"]
    items = sorted(d.items())
    for i, (key, value) in enumerate(items):
        comma = "," if i < len(items) - 1 else ""
        if isinstance(value, dict):
            inner = format_dict_compact(value)
            lines.append(f'    "{key}": {inner}{comma}')
        else:
            lines.append(f'    "{key}": {json.dumps(value, ensure_ascii=False)}{comma}')
    lines.append("}")
    return "\n".join(lines)

def main():
    if len(sys.argv) != 4:
        print("用法: build_multi_char_dict.py <字典目录> <模板py路径> <输出py路径>")
        sys.exit(1)

    dict_dir = sys.argv[1]
    template_path = sys.argv[2]
    output_path = sys.argv[3]

    print("正在提取一字对多字映射...")
    multi_char_dict = build_multi_char_dict(dict_dir)

    total = sum(len(v) for v in multi_char_dict.values())
    print(f"共提取 {total} 个多字映射，分布在 {len(multi_char_dict)} 个字典文件中")

    # 读取模板
    with open(template_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # 生成追加内容
    append_content = f"""

# ======================== 一字对多字映射（编译期自动生成） ========================

MULTI_CHAR_DICT = {format_dict_compact(multi_char_dict)}

# 配置名 → 字符字典名映射
CONFIG_TO_CHAR_DICT = {{
    's2t':      'STCharacters',
    's2tw':     'STCharacters',
    's2twp':    'STCharacters',
    's2hk':     'STCharacters',
    's2hkp':    'STCharacters',
    't2s':      'TSCharacters',
    'tw2s':     'TSCharacters',
    'tw2sp':    'TSCharacters',
    'hk2s':     'TSCharacters',
    'hk2sp':    'TSCharacters',
    't2tw':     'TWVariants',
    'tw2t':     'TWVariantsRev',
    't2hk':     'HKVariants',
    'hk2t':     'HKVariantsRev',
    't2jp':     'JPShinjitaiCharacters',
    'jp2t':     'JPShinjitaiCharactersRev',
    # jieba 版
    's2t_jieba':     'STCharacters',
    's2tw_jieba':    'STCharacters',
    's2twp_jieba':   'STCharacters',
    's2hk_jieba':    'STCharacters',
    's2hkp_jieba':   'STCharacters',
    'hk2sp_jieba':   'TSCharacters',
    'tw2sp_jieba':   'TSCharacters',
}}
"""

    # 追加到末尾
    content = content + append_content

    # 写出到编译目录
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"已生成: {output_path}")


if __name__ == '__main__':
    main()