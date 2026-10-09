#!/usr/bin/env python3
"""Validate and transform a dashboard snapshot without publishing it."""

import argparse
from datetime import datetime, timezone
import json
import re
import sys


class InvalidDashboard(ValueError):
    pass


def visible_lines(lines):
    visible = []
    fence = None
    for line in lines:
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence is not None:
            visible.append(False)
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                if not line[marker.end():].strip():
                    fence = None
        elif marker:
            fence = marker[1]
            visible.append(False)
        else:
            visible.append(True)
    return visible


def heading(line):
    match = re.match(r"^ {0,3}(#{1,6})[ \t]+(.+?)\s*$", line)
    if not match:
        return None
    title = re.sub(r"[ \t]+#+$", "", match[2]).strip()
    return len(match[1]), title


def section_bounds(lines, visible, title):
    matches = [
        (index, heading(line)[0]) for index, line in enumerate(lines)
        if visible[index] and heading(line) and heading(line)[1] == title
    ]
    if len(matches) != 1:
        raise InvalidDashboard(f"expected exactly one section {title!r}; found {len(matches)}")
    start, level = matches[0]
    end = next(
        (index for index in range(start + 1, len(lines))
         if visible[index] and heading(lines[index]) and heading(lines[index])[0] <= level),
        len(lines),
    )
    return start + 1, end


def cells(line):
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return None
    return [cell.strip() for cell in stripped[1:-1].split("|")]


def separator(values):
    return values is not None and all(re.fullmatch(r":?-{3,}:?", cell) for cell in values)


def table_bounds(lines, visible, start, end):
    tables = []
    for index in range(start, end - 1):
        header, rule = cells(lines[index]), cells(lines[index + 1])
        if (visible[index] and visible[index + 1] and header and len(header) == 5
                and [value.lower() for value in header[:2]] == ["status", "repo"]
                and rule and len(rule) == 5 and separator(rule)):
            tables.append(index)
    if len(tables) != 1:
        raise InvalidDashboard(f"expected exactly one five-column Status/Repo table; found {len(tables)}")
    header = tables[0]
    last = header + 2
    while last < end and visible[last] and lines[last].lstrip().startswith("|"):
        values = cells(lines[last])
        if (values is None or len(values) != 5 or separator(values)
                or values == cells(lines[header])):
            raise InvalidDashboard("malformed or repeated header/separator inside data rows")
        last += 1
    return header + 2, last


def single_line(value):
    if not value or any(char in value for char in "|\r\n"):
        raise InvalidDashboard("values and patterns must be nonempty single lines without pipes")
    return value


def row(values):
    return "| " + " | ".join(values) + " |\n"


def transform(body, args):
    lines = body.splitlines(keepends=True)
    visible = visible_lines(lines)
    if args.command in ("add-row", "update-row", "remove-row"):
        start, end = section_bounds(lines, visible, args.section or "Active Work Streams")
        first, last = table_bounds(lines, visible, start, end)
        if args.command == "add-row":
            values = [single_line(value) for value in
                      (args.status, args.repo, args.url, args.description, args.timestamp)]
            values[2] = f"[{values[2]}]({values[2]})"
            if last and not lines[last - 1].endswith(("\n", "\r")):
                lines[last - 1] += "\n"
            lines.insert(last, row(values))
        else:
            pattern = single_line(args.pattern)
            matches = [index for index in range(first, last) if pattern in lines[index]]
            if len(matches) != 1:
                raise InvalidDashboard(f"expected exactly one matching data row; found {len(matches)}")
            index = matches[0]
            if args.command == "remove-row":
                del lines[index]
            else:
                updates = {0: args.status, 2: args.link,
                           3: args.description, 4: args.timestamp}
                if not any(value is not None for value in updates.values()):
                    raise InvalidDashboard("update-row requires at least one field option")
                values = cells(lines[index])
                for position, value in updates.items():
                    if value is not None:
                        value = single_line(value)
                        values[position] = f"[{value}]({value})" if position == 2 else value
                lines[index] = row(values)
    elif args.command == "add-note":
        _, end = section_bounds(lines, visible, args.section or "Notes")
        text = single_line(args.text)
        if end and not lines[end - 1].endswith(("\n", "\r")):
            lines[end - 1] += "\n"
        lines.insert(end, f"- {text}\n")
    else:
        start, end = (section_bounds(lines, visible, args.section)
                      if args.section else (0, len(lines)))
        expression = r"^(\s*(?:\*\*)?[Ll]ast refreshed(?:\*\*)?:(?:\*\*)?)[ \t]*.*$"
        matches = [
            (index, re.match(expression, lines[index].rstrip("\r\n")))
            for index in range(start, end) if visible[index]
        ]
        matches = [(index, match) for index, match in matches if match]
        if len(matches) != 1:
            raise InvalidDashboard(f"expected exactly one Last refreshed line; found {len(matches)}")
        index, match = matches[0]
        lines[index] = match[1] + " " + datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M UTC\n")
    return "".join(lines)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--section", help="exact Markdown heading")
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add-row")
    for field in ("status", "repo", "url", "description", "timestamp"):
        add.add_argument(field)
    update = commands.add_parser("update-row")
    update.add_argument("pattern")
    for field in ("status", "description", "timestamp", "link"):
        update.add_argument("--" + field)
    remove = commands.add_parser("remove-row")
    remove.add_argument("pattern")
    commands.add_parser("add-note").add_argument("text")
    commands.add_parser("refresh-timestamp")
    return parser.parse_args()


def main():
    args = arguments()
    try:
        envelope = json.load(sys.stdin)
        if not isinstance(envelope, dict) or not isinstance(envelope.get("body"), str):
            raise InvalidDashboard("issue response must contain a string body")
        proposed = transform(envelope["body"], args)
    except (InvalidDashboard, json.JSONDecodeError) as error:
        print(f"Dashboard: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(proposed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
