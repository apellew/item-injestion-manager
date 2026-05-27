#!/usr/bin/env python3
"""
_parse_name.py — parse a source path against a regex and expand a template.

Usage:
    python3 _parse_name.py REGEX TEMPLATE SOURCE

Behaviour:
    - Matches REGEX against SOURCE using re.fullmatch (anchored on both ends).
    - If no match, exits with code 2 — the calling shell script maps this
      to a `parse_error` rejection using the existing rejection mechanism.
    - If matched, expands TEMPLATE by replacing every "%NAME%" occurrence
      with the corresponding capture group's value. Capture groups use
      Python's named-group syntax: (?P<NAME>...).
    - Optional capture groups that did not match are replaced with empty
      strings (so a template containing %YEAR% won't produce a literal
      "%YEAR%" in the output when YEAR wasn't captured — instead, the
      space around it might collapse to look like " ()" which the user
      should handle in their regex/template design).
    - Prints the expanded template to stdout, then exits 0.

Exit codes:
    0 = matched and template expanded successfully
    2 = regex did not match the source string (parse_error)
    3 = invalid arguments or invalid regex syntax

This script is not a child of the orchestrator. The leading underscore
in the filename keeps it out of the orchestrator's ingest-*.zsh glob,
matching the convention used for _lib.zsh.
"""

import re
import sys


def main():
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} REGEX TEMPLATE SOURCE", file=sys.stderr)
        sys.exit(3)

    regex, template, source = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        pattern = re.compile(regex)
    except re.error as e:
        print(f"invalid regex: {e}", file=sys.stderr)
        sys.exit(3)

    match = pattern.fullmatch(source)
    if not match:
        # Calling script maps this to a parse_error rejection.
        sys.exit(2)

    result = template
    for name, value in match.groupdict().items():
        result = result.replace(f"%{name}%", value if value is not None else "")

    print(result)


if __name__ == "__main__":
    main()
