#!/usr/bin/env python3
"""
生成 OpenCC 拼音词典和首字母词典。

Usage:
    python gen_pinyin_dicts.py dict --input <zdic.txt> --output <pinyin.txt>
    python gen_pinyin_dicts.py phrase --phrase <large_pinyin.txt> --pinyin <pinyin.txt> --output <phrase_pinyin.txt>
    python gen_pinyin_dicts.py init_letter --input <large_pinyin.txt> --pinyin <pinyin.txt> --output <phrase_init_letter.txt>
    python gen_pinyin_dicts.py init_letter --input <pinyin.txt> --output <pinyin_init_letter.txt>

dict        - 从 zdic.txt 生成单字拼音词典
phrase      - 从 large_pinyin.txt 生成多音字词组拼音词典
init_letter - 生成首字母词典（词组模式需 --pinyin 过滤，单字模式不需要）
"""

import argparse
import re
import sys
from collections import OrderedDict, Counter
from pathlib import Path


# ======================== 带调字母 → ASCII 字母映射 ========================

_TONE_TO_ASCII = {
    'à': 'a', 'á': 'a', 'ā': 'a', 'ǎ': 'a',
    'è': 'e', 'é': 'e', 'ē': 'e', 'ě': 'e',
    'ì': 'i', 'í': 'i', 'ī': 'i', 'ǐ': 'i',
    'ò': 'o', 'ó': 'o', 'ō': 'o', 'ǒ': 'o',
    'ù': 'u', 'ú': 'u', 'ū': 'u', 'ǔ': 'u',
    'ǖ': 'ü', 'ǘ': 'ü', 'ǚ': 'ü', 'ǜ': 'ü',
    'ń': 'n', 'ň': 'n', 'ǹ': 'n',
    'ḿ': 'm',
}


# ======================== 行尾注释处理 ========================

def strip_inline_comment(text: str) -> str:
    """去掉 # 及其之后的内容，并 strip 尾部空格"""
    if '#' in text:
        text = text.split('#')[0].strip()
    return text


# ======================== dict 命令 ========================

_LINE_RE = re.compile(r'^U\+([0-9A-Fa-f]+):\s+(\S+)\s+#')


def parse_zdic(content: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        codepoint_hex, pinyins_str = m.group(1), m.group(2)
        char = chr(int(codepoint_hex, 16))
        readings = pinyins_str.split(',')
        entries.append((char, ' '.join(readings)))
    return entries


def write_opencc_dict(entries: list[tuple[str, str]], output_path: Path) -> None:
    with output_path.open('w', encoding='utf-8') as fh:
        for key, value in entries:
            fh.write(f'{key}\t{value}\n')


def cmd_dict(args):
    zdic_path = Path(args.input)
    if not zdic_path.exists():
        print(f'Error: {zdic_path} not found.', file=sys.stderr)
        sys.exit(1)
    content = zdic_path.read_text(encoding='utf-8')
    entries = parse_zdic(content)
    write_opencc_dict(entries, Path(args.output))
    print(f'Wrote {len(entries)} entries to {args.output}')


# ======================== phrase 命令 ========================


def load_polyphonic_chars(pinyin_path: Path) -> set[str]:
    polyphonic_chars: set[str] = set()
    for line in pinyin_path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '\t' not in line:
            continue
        char, values = line.split('\t', 1)
        values = strip_inline_comment(values)
        if len(values.split()) > 1:
            polyphonic_chars.add(char)
    return polyphonic_chars


def parse_phrase_line(line: str) -> tuple[str, list[str]] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith('#') or ':' not in stripped:
        return None
    phrase, reading = stripped.split(':', 1)
    phrase = phrase.strip()
    reading = strip_inline_comment(reading)
    syllables = reading.split()
    if not phrase or not syllables:
        return None
    return phrase, syllables


def generate_phrase_entries(
    phrase_content: str,
    polyphonic_chars: set[str],
) -> OrderedDict[str, list[str]]:
    entries: OrderedDict[str, list[str]] = OrderedDict()
    for line in phrase_content.splitlines():
        parsed = parse_phrase_line(line)
        if parsed is None:
            continue
        phrase, syllables = parsed
        if len(phrase) < 2 or not any(char in polyphonic_chars for char in phrase):
            continue
        reading = ''.join(syllables)
        readings = entries.setdefault(phrase, [])
        if reading not in readings:
            readings.append(reading)
    return entries


def write_phrase_dict(entries: OrderedDict[str, list[str]], output_path: Path) -> None:
    with output_path.open('w', encoding='utf-8') as fh:
        for phrase, readings in entries.items():
            fh.write(f'{phrase}\t{" ".join(readings)}\n')


def cmd_phrase(args):
    phrase_path = Path(args.phrase)
    pinyin_path = Path(args.pinyin)
    output_path = Path(args.output)

    polyphonic_chars = load_polyphonic_chars(pinyin_path)
    phrase_content = phrase_path.read_text(encoding='utf-8')
    entries = generate_phrase_entries(phrase_content, polyphonic_chars)
    write_phrase_dict(entries, output_path)

    reading_count = sum(len(readings) for readings in entries.values())
    print(f'Wrote {len(entries)} phrase entries ({reading_count} readings) to {args.output}')


# ======================== strip_tone 命令 ========================

def cmd_strip_tone(args):
    input_path = Path(args.input)
    output_path = Path(args.output)

    with input_path.open('r', encoding='utf-8') as fin, \
         output_path.open('w', encoding='utf-8') as fout:
        for line in fin:
            line = line.strip()
            if not line or line.startswith('#') or '\t' not in line:
                fout.write(line + '\n')
                continue
            key, values = line.split('\t', 1)
            values = strip_inline_comment(values)
            result = ''.join(_TONE_TO_ASCII.get(ch, ch) for ch in values)
            fout.write(f'{key}\t{result}\n')

    print(f'Wrote to {args.output}')


# ======================== init_letter 命令 ========================


def syllable_to_initial(syllable: str, stats: Counter) -> str:
    """取一个音节的首字母大写，带调字母查表替换，统计不认识的非 ASCII 首字母"""
    if not syllable:
        return ''
    ch = syllable[0]
    if ch.isascii() and ch.isalpha():
        return ch.upper()
    mapped = _TONE_TO_ASCII.get(ch)
    if mapped:
        stats['tone_mapped'] += 1
        return mapped.upper()
    stats['unknown_initial'] += 1
    stats['unknown_samples'].append(f'{syllable} → U+{ord(ch):04X}')
    return ch.upper()


def cmd_init_letter(args):
    input_path = Path(args.input)
    output_path = Path(args.output)
    stats = Counter()
    stats['unknown_samples'] = []

    if args.pinyin:
        # 词组模式：从 large_pinyin.txt + pinyin.txt 过滤生成
        pinyin_path = Path(args.pinyin)
        polyphonic_chars = load_polyphonic_chars(pinyin_path)
        phrase_content = input_path.read_text(encoding='utf-8')

        entries: OrderedDict[str, list[str]] = OrderedDict()
        for line in phrase_content.splitlines():
            parsed = parse_phrase_line(line)
            if parsed is None:
                continue
            phrase, syllables = parsed
            if len(phrase) < 2 or not any(char in polyphonic_chars for char in phrase):
                continue
            initials = ''.join(syllable_to_initial(s, stats) for s in syllables)
            readings = entries.setdefault(phrase, [])
            if initials not in readings:
                readings.append(initials)

        with output_path.open('w', encoding='utf-8') as fh:
            for phrase, readings in entries.items():
                fh.write(f'{phrase}\t{" ".join(readings)}\n')

        reading_count = sum(len(readings) for readings in entries.values())
        print(f'Wrote {len(entries)} phrase init_letter entries ({reading_count} readings) to {args.output}')
    else:
        # 单字模式：从 pinyin.txt 直接生成
        entries: list[tuple[str, str]] = []
        for line in input_path.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '\t' not in line:
                continue
            char, values = line.split('\t', 1)
            values = strip_inline_comment(values)
            initials = ' '.join(syllable_to_initial(s, stats) for s in values.split())
            entries.append((char, initials))

        with output_path.open('w', encoding='utf-8') as fh:
            for key, value in entries:
                fh.write(f'{key}\t{value}\n')

        print(f'Wrote {len(entries)} init_letter entries to {args.output}')

    # 打印统计
    if stats['tone_mapped']:
        print(f'[init_letter] tone→ASCII mappings: {stats["tone_mapped"]}', file=sys.stderr)
    if stats['unknown_initial']:
        print(f'[init_letter] WARNING: {stats["unknown_initial"]} unknown non-ASCII initials:', file=sys.stderr)
        for s in stats['unknown_samples'][:20]:
            print(f'  {s}', file=sys.stderr)
        if len(stats['unknown_samples']) > 20:
            print(f'  ... and {len(stats["unknown_samples"]) - 20} more', file=sys.stderr)


# ======================== 主入口 ========================

def main():
    parser = argparse.ArgumentParser(description='生成 OpenCC 拼音词典和首字母词典')
    subparsers = parser.add_subparsers(dest='command', required=True)

    # dict
    p_dict = subparsers.add_parser('dict', help='生成单字拼音词典')
    p_dict.add_argument('--input', required=True)
    p_dict.add_argument('--output', required=True)

    # phrase
    p_phrase = subparsers.add_parser('phrase', help='生成词组拼音词典')
    p_phrase.add_argument('--phrase', required=True)
    p_phrase.add_argument('--pinyin', required=True)
    p_phrase.add_argument('--output', required=True)

    # strip_tone
    p_strip = subparsers.add_parser('strip_tone', help='去除拼音声调')
    p_strip.add_argument('--input', required=True)
    p_strip.add_argument('--output', required=True)

    # init_letter
    p_init = subparsers.add_parser('init_letter', help='生成首字母词典')
    p_init.add_argument('--input', required=True)
    p_init.add_argument('--pinyin', default=None)
    p_init.add_argument('--output', required=True)

    args = parser.parse_args()

    if args.command == 'dict':
        cmd_dict(args)
    elif args.command == 'phrase':
        cmd_phrase(args)
    elif args.command == 'strip_tone':
        cmd_strip_tone(args)
    elif args.command == 'init_letter':
        cmd_init_letter(args)


if __name__ == '__main__':
    main()