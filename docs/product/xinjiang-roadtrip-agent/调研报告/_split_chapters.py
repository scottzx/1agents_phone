#!/usr/bin/env python3
"""Split markitdown PDF output into chapter markdown files."""

from __future__ import annotations

import re
from pathlib import Path

SRC = Path(__file__).resolve().parent / "markdown" / "_full.md"
OUT_DIR = Path(__file__).resolve().parent / "index"

CHAPTERS = [
    ("1", "概述", "01-概述.md"),
    ("2", "项目建设背景和必要性", "02-项目建设背景和必要性.md"),
    ("3", "项目需求分析与产出方案", "03-项目需求分析与产出方案.md"),
    ("4", "项目选址与建设条件", "04-项目选址与建设条件.md"),
    ("5", "项目建设方案", "05-项目建设方案.md"),
    ("6", "项目投资估算和资金筹措", "06-项目投资估算和资金筹措.md"),
    ("7", "项目影响效果分析", "07-项目影响效果分析.md"),
    ("8", "项目风险管控方案", "08-项目风险管控方案.md"),
    ("9", "研究结论及建议", "09-研究结论及建议.md"),
]

CHAPTER5_SECTIONS = [
    ("5.1", "新疆全域自驾游服务体系建设总体研究", "05.1-服务体系建设总体研究.md"),
    ("5.2", "新疆全域自驾游数据资源平台及自驾游线上租车应用信息化建设项目", "05.2-数据资源平台及线上租车应用.md"),
    ("5.3", "新疆全域自驾游阿拉尔运营中心选址和规划设计", "05.3-阿拉尔运营中心选址和规划设计.md"),
    ("5.4", "新疆全域自驾游运营中心改造项目（临时业务用房）", "05.4-运营中心改造项目.md"),
    ("5.5", "新疆全域自驾游精细化管理项目", "05.5-精细化管理项目.md"),
]

PAGE_HEADER = "新疆全域自驾游服务体系建设项目一期可行性研究报告"
PAGE_NUM_RE = re.compile(r"^-\s*\d+\s*-$")
TOC_DOTS_RE = re.compile(r".\s*\.{5,}")
HEADING_RE = re.compile(r"^(\d+(?:\.\d+)*)\s+(\S.*)$")
LIST_RE = re.compile(
    r"^("
    r"\(\d+\)"
    r"|[（][0-9一二三四五六七八九十]+[）]"
    r"|\d+[\.、．]\s*"
    r"|[一二三四五六七八九十]+[、．]"
    r")"
)
CAPTION_RE = re.compile(r"^(图|表)\s*[\d.．-]+")
DOC_TITLE_RE = re.compile(r"^新疆全域自驾游服务体系建设项目一期可行性研究报告$")
SENTENCE_END = ("。", "！", "？", "…")
SOFT_BREAK = ("，", "、", "；", ",", ";", "：", ":")


def norm_spaces(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def is_noise(line: str) -> bool:
    if not line:
        return False
    if line in {"\x0c", "\f"}:
        return True
    if line == PAGE_HEADER:
        return True
    if PAGE_NUM_RE.match(line):
        return True
    if line in {"目        录", "目 录", "目录"}:
        return True
    return False


def is_toc_line(line: str) -> bool:
    return bool(TOC_DOTS_RE.search(line))


def heading_level(number: str) -> int:
    return min(number.count(".") + 1, 6)


def parse_heading(line: str) -> tuple[str, str] | None:
    m = HEADING_RE.match(line)
    if not m:
        return None
    number, title = m.group(1), norm_spaces(m.group(2))
    compact = title.replace(" ", "")
    if number.count(".") == 0:
        known = {num: name for num, name, _ in CHAPTERS}
        if known.get(number) != compact:
            return None
        title = known[number]
    else:
        if len(compact) > 60:
            return None
        if re.search(r"[。！？]", title):
            return None
        if re.match(r"^\d+\.\d{2,}$", number):
            return None
        if not re.match(r"^[\u4e00-\u9fff“\"《(（A-Za-z]", title):
            return None
        if re.match(r"^(亿元|万元|元|个|家|公里|平方米|套)", compact):
            return None
    return number, title


def is_prose_fragment(text: str) -> bool:
    compact = norm_spaces(text)
    if compact.endswith(SOFT_BREAK):
        return True
    if compact.endswith(("》", "）", ")", "”", "’")) and len(compact) >= 16:
        return True
    return len(compact) >= 20


def should_join(prev: str, curr: str) -> bool:
    if prev.endswith(SENTENCE_END):
        return False
    if LIST_RE.match(curr) or CAPTION_RE.match(curr):
        return False
    return is_prose_fragment(prev)


def is_list_continuation(prev: str, curr: str) -> bool:
    if CAPTION_RE.match(curr) or LIST_RE.match(curr):
        return False
    if prev.endswith(SENTENCE_END):
        return False
    if prev.endswith(SOFT_BREAK) or prev.endswith(("（", "(", "《", "—")):
        return True
    if prev[-1].isascii() and prev[-1].isalpha():
        return True
    return is_prose_fragment(prev) and len(norm_spaces(curr)) < 18


def join_zh(parts: list[str]) -> str:
    if not parts:
        return ""
    result = parts[0]
    for part in parts[1:]:
        if not part:
            continue
        if result and result[-1].isascii() and part[0].isascii():
            result += " " + part
        else:
            result += part
    return result


def emit_blank(out: list[str]) -> None:
    if out and out[-1] != "":
        out.append("")


def clean_lines(raw_lines: list[str]) -> list[str]:
    lines = [ln.replace("\x0c", "").strip() for ln in raw_lines]
    out: list[str] = []
    buf: list[str] = []

    def flush() -> None:
        nonlocal buf
        if buf:
            out.append(join_zh(buf))
            buf = []

    for line in lines:
        if is_noise(line) or is_toc_line(line) or DOC_TITLE_RE.match(line):
            continue
        if not line:
            continue
        heading = parse_heading(line)
        if heading:
            flush()
            number, title = heading
            emit_blank(out)
            out.append(f"{'#' * heading_level(number)} {number} {title}")
            emit_blank(out)
            continue
        if CAPTION_RE.match(line):
            flush()
            emit_blank(out)
            out.append(norm_spaces(line))
            emit_blank(out)
            continue
        if LIST_RE.match(line):
            flush()
            if out and out[-1] and not LIST_RE.match(out[-1]):
                emit_blank(out)
            buf = [line]
            if line.endswith(SENTENCE_END):
                flush()
            continue
        if buf and LIST_RE.match(buf[0]):
            if is_list_continuation(buf[-1], line):
                buf.append(line)
                if line.endswith(SENTENCE_END):
                    flush()
                continue
            flush()
            emit_blank(out)
        if buf and should_join(buf[-1], line):
            buf.append(line)
        else:
            flush()
            emit_blank(out)
            buf = [line]
        if buf and buf[-1].endswith(SENTENCE_END):
            flush()
            emit_blank(out)

    flush()
    collapsed: list[str] = []
    for line in out:
        if line == "" and collapsed and collapsed[-1] == "":
            continue
        collapsed.append(line)
    return collapsed


def find_heading_index(lines: list[str], number: str, title: str) -> int:
    prefix = f"{'#' * heading_level(number)} {number} {title}"
    for i, line in enumerate(lines):
        if line == prefix:
            return i
    raise SystemExit(f"heading not found: {number} {title}")


def write_md(path: Path, title: str, body: list[str], extra_header: str = "") -> None:
    while body and body[0] == "":
        body = body[1:]
    while body and body[-1] == "":
        body = body[:-1]
    parts = [f"# {title}", ""]
    if extra_header:
        parts.extend([extra_header, ""])
    parts.extend(body)
    parts.append("")
    path.write_text("\n".join(parts), encoding="utf-8")


def main() -> None:
    raw = SRC.read_text(encoding="utf-8").splitlines()
    lines = clean_lines(raw)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    starts: dict[str, int] = {}
    for number, title, _ in CHAPTERS:
        starts[number] = find_heading_index(lines, number, title)
    for number, title, _ in CHAPTER5_SECTIONS:
        starts[number] = find_heading_index(lines, number, title)

    # 00 front matter: leftover before chapter 1 (usually empty after TOC strip)
    front = lines[: starts["1"]]
    front = [ln for ln in front if ln.strip()]
    if front:
        write_md(OUT_DIR / "00-封面与目录.md", "封面与目录", front)

    for i, (number, title, filename) in enumerate(CHAPTERS):
        start = starts[number]
        end = starts[CHAPTERS[i + 1][0]] if i + 1 < len(CHAPTERS) else len(lines)
        chunk = lines[start:end]

        if number != "5":
            # drop the duplicated top heading; file title already has it
            if chunk and chunk[0].startswith("# "):
                chunk = chunk[1:]
            write_md(OUT_DIR / filename, f"{number} {title}", chunk)
            continue

        intro_end = starts["5.1"]
        intro = lines[start + 1 : intro_end]
        links = [
            "本章体量较大，已按子项目拆分为以下文件：",
            "",
        ]
        for sec_num, sec_title, sec_file in CHAPTER5_SECTIONS:
            links.append(f"- [{sec_num} {sec_title}](./{sec_file})")
        write_md(OUT_DIR / filename, f"{number} {title}", intro, "\n".join(links))

        for j, (sec_num, sec_title, sec_file) in enumerate(CHAPTER5_SECTIONS):
            sec_start = starts[sec_num]
            sec_end = (
                starts[CHAPTER5_SECTIONS[j + 1][0]]
                if j + 1 < len(CHAPTER5_SECTIONS)
                else end
            )
            sec_chunk = lines[sec_start:sec_end]
            if sec_chunk and sec_chunk[0].startswith("#"):
                sec_chunk = sec_chunk[1:]
            write_md(OUT_DIR / sec_file, f"{sec_num} {sec_title}", sec_chunk)

    index_lines = [
        "# 新疆全域自驾游服务体系建设项目一期可行性研究报告",
        "",
        "> 来源：`新疆全域自驾游服务体系建设项目一期可行性研究报告（5月8日改新）.pdf`",
        "> 转换工具：markitdown；已按章节拆分，便于检索与引用。",
        "",
        "## 目录",
        "",
    ]
    if (OUT_DIR / "00-封面与目录.md").exists():
        index_lines.append("- [封面与目录](./00-封面与目录.md)")

    for number, title, filename in CHAPTERS:
        index_lines.append(f"- [{number} {title}](./{filename})")
        if number == "5":
            for sec_num, sec_title, sec_file in CHAPTER5_SECTIONS:
                index_lines.append(f"  - [{sec_num} {sec_title}](./{sec_file})")

    index_lines.extend(["", "## 阅读说明", ""])
    index_lines.extend(
        [
            "- 原文为扫描/排版 PDF，转换后已去掉页眉页脚和页码，并尽量合并被分页打断的段落。",
            "- 第 5 章建设方案最长，按 5.1–5.5 五个子项目单独成文。",
            "- 表格、图示在 PDF 中多为版式对象，文本还原可能不完整，涉及数据时请对照原 PDF。",
            "- 完整原文备份见 `../markdown/_full.md`。",
            "",
        ]
    )
    index_text = "\n".join(index_lines)
    (OUT_DIR / "README.md").write_text(index_text, encoding="utf-8")
    (OUT_DIR / "index.md").write_text(index_text, encoding="utf-8")

    print(f"wrote {OUT_DIR}")
    for p in sorted(OUT_DIR.iterdir()):
        text = p.read_text(encoding="utf-8")
        print(f"  {p.name:50s}  {len(text.splitlines()):5d} lines  {p.stat().st_size:7d} bytes")


if __name__ == "__main__":
    main()
