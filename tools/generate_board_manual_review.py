"""Build a self-contained review page from board manual Markdown drafts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


TEMPLATE = Path(__file__).with_name("board_manual_review.html")
DATA_MARKER = "__BOARD_REVIEW_DATA__"
PORT_MARKER = "__BOARD_REVIEW_PORT__"
HEADING = re.compile(r"^(#{1,3})\s+(\S.*)$")
CONNECTOR = re.compile(r"^([A-Za-z]+[0-9]+(?:[-_][A-Za-z0-9]+)*)\s+—\s+\S.*$")
COLUMN_SEPARATOR = re.compile(r":?-{3,}:?")


def table_cells(line: str) -> list[str]:
    return [
        value.strip().replace(r"\|", "|").replace("<br>", "\n")
        for value in re.split(r"(?<!\\)\|", line[1:-1])
    ]


def read_table(lines: list[str], start: int) -> tuple[dict, int]:
    headers = table_cells(lines[start])
    index = start + 1
    rows = []
    if index >= len(lines) or not (lines[index].startswith("|") and lines[index].endswith("|")):
        raise ValueError(f"line {start + 1}: table header needs a separator row")
    separator = table_cells(lines[index])
    if len(separator) != len(headers) or not all(COLUMN_SEPARATOR.fullmatch(cell) for cell in separator):
        raise ValueError(f"line {index + 1}: invalid table separator row")

    index += 1
    while index < len(lines) and lines[index].startswith("|"):
        if not lines[index].endswith("|"):
            raise ValueError(f"line {index + 1}: table row needs a closing pipe")
        row = table_cells(lines[index])
        if len(row) != len(headers):
            raise ValueError(f"line {index + 1}: table row must have {len(headers)} cells")
        rows.append(row)
        index += 1
    return {"kind": "table", "headers": headers, "rows": rows}, index


def classify_review_blocks(section: dict) -> None:
    blocks = section["blocks"]
    connector = section["match"].startswith("connector:")
    first_table = next((index for index, block in enumerate(blocks) if block["kind"] == "table"), None)
    if connector and first_table is not None:
        # The manual generator writes two figure captions immediately before the pin table.
        before_table = blocks[:first_table]
        if len(before_table) >= 2 and all(block["kind"] == "paragraph" for block in before_table[-2:]):
            for block in before_table[-2:]:
                block["role"] = "caption"
    elif first_table is None and section["id"] != "cover":
        for heading, paragraph in zip(blocks, blocks[1:]):
            if heading["kind"] == "heading" and paragraph["kind"] == "paragraph":
                paragraph["role"] = "caption"
    for block in blocks:
        if block["kind"] == "table":
            block["role"] = "overview" if not connector and len(block["headers"]) == 2 else "reference"


def parse_draft(path: Path) -> dict:
    source = path.read_bytes()
    lines = [line.strip() for line in source.decode("utf-8-sig").splitlines()]
    opening = [index for index, line in enumerate(lines) if line][:2]
    if len(opening) != 2:
        raise ValueError("expected a document title and board subtitle from --review-only")
    document_heading = HEADING.fullmatch(lines[opening[0]])
    board_heading = HEADING.fullmatch(lines[opening[1]])
    if not document_heading or document_heading[1] != "#" or not board_heading or board_heading[1] != "##":
        raise ValueError("expected a document title and board subtitle from --review-only")

    title, subtitle = document_heading[2], board_heading[2]
    cover = {
        "id": "cover", "match": "cover", "title": title,
        "blocks": [{"kind": "heading", "text": subtitle}],
    }
    sections = [cover]
    chapter = current = cover
    connectors = set()
    group_ids = set()
    chapter_counts: dict[str, int] = {}

    index = opening[1] + 1
    while index < len(lines):
        line = lines[index]
        if heading := HEADING.fullmatch(line):
            level, label = heading.groups()
            if level == "##":
                match = f"chapter:{label.casefold()}"
                count = chapter_counts.get(match, 0) + 1
                chapter_counts[match] = count
                if count > 1:
                    match = f"repeated-{match}:{count}"
                chapter = current = {"id": match, "match": match, "title": label, "blocks": []}
                sections.append(current)
            elif level == "###" and (connector := CONNECTOR.fullmatch(label)):
                match = f"connector:{connector[1].upper()}"
                if match in connectors:
                    raise ValueError(f"line {index + 1}: repeated connector {connector[1]}")
                connectors.add(match)
                group_ids.add(chapter["id"])
                current = {
                    "id": match, "match": match, "title": label,
                    "group": chapter["title"], "blocks": [],
                }
                sections.append(current)
            else:
                current["blocks"].append({"kind": "heading", "text": label})
        elif line.startswith("|"):
            if not line.endswith("|"):
                raise ValueError(f"line {index + 1}: table header needs a closing pipe")
            table, index = read_table(lines, index)
            current["blocks"].append(table)
            continue
        elif line:
            if index > 0 and lines[index - 1] and current["blocks"] and current["blocks"][-1]["kind"] == "paragraph":
                current["blocks"][-1]["text"] += "\n" + line
            else:
                current["blocks"].append({"kind": "paragraph", "text": line})
        index += 1

    for section in sections:
        classify_review_blocks(section)
    revision = hashlib.sha256(source).hexdigest()
    return {
        "title": subtitle,
        "id": revision,
        "revision": revision,
        "sections": [section for section in sections if section["blocks"] or section["id"] not in group_ids],
    }


def build_page(paths: list[Path], output: Path, app_port: int = 8765) -> None:
    destination = output.resolve()
    if destination == TEMPLATE.resolve():
        raise ValueError("the output must leave the review page template intact")
    if any(destination == path.resolve() for path in paths):
        raise ValueError("the output must be different from the input drafts")

    drafts = []
    draft_ids = set()
    for path in paths:
        try:
            draft = parse_draft(path)
        except ValueError as error:
            raise ValueError(f"{path}: {error}") from error
        if draft["id"] in draft_ids:
            raise ValueError(f"duplicate draft content: {path}")
        draft_ids.add(draft["id"])
        drafts.append(draft)

    titles = [draft["title"] for draft in drafts]
    for index, (draft, title) in enumerate(zip(drafts, titles), start=1):
        if titles.count(title) > 1:
            draft["title"] = f"{title} (Draft {index})"

    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count(DATA_MARKER) != 1:
        raise ValueError(f"expected one data marker in {TEMPLATE.name}")
    # Escape the opening angle bracket so draft text cannot close the JSON script element.
    data = json.dumps({"version": 1, "drafts": drafts}, ensure_ascii=False).replace("<", r"\u003c")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(template.replace(DATA_MARKER, data).replace(PORT_MARKER, str(app_port)), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("drafts", nargs="+", type=Path, help="Markdown drafts from --review-only")
    parser.add_argument("--output", required=True, type=Path, help="Destination .html file")
    parser.add_argument("--app-port", type=int, default=8765, help="Local autosave app port (default: 8765)")
    args = parser.parse_args()
    if args.output.suffix.lower() != ".html":
        parser.error("--output must name an .html file")
    if not 1 <= args.app_port <= 65535:
        parser.error("--app-port must be between 1 and 65535")
    try:
        build_page(args.drafts, args.output, args.app_port)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(args.output)


if __name__ == "__main__":
    main()
