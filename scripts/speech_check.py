#!/usr/bin/env python3
"""Scores a transcript against a fixture's reference text.

Usage: python3 scripts/speech_check.py <language> <reference> <transcript>

Prints the error rate: word error rate for languages written with spaces,
character error rate for Chinese and Japanese. Case, punctuation and spacing
don't count.

>>> round(error_rate("en", "However, due to the slow channels.", "however due to the slow channels"), 3)
0.0
>>> round(error_rate("en", "styles could lag by 25 to 30 year", "styles could lag by 25 to 30 years"), 3)
0.125
>>> round(error_rate("zh", "日本原子能机构表示。", "日本原子能机构表示"), 3)
0.0
>>> round(error_rate("ja", "しかし、通信経路", "しかし通信系路"), 3)
0.143
>>> error_rate("en", "hello", "")
1.0
"""

import sys
import unicodedata

CHARACTER_LANGUAGES = {"zh", "ja", "yue"}


def units(language: str, text: str) -> list:
    """Words (or characters) with punctuation and case removed."""
    kept = "".join(
        ch.lower() if not unicodedata.category(ch).startswith(("P", "S")) else " "
        for ch in unicodedata.normalize("NFKC", text)
    )
    if language in CHARACTER_LANGUAGES:
        return [ch for ch in kept if not ch.isspace()]
    return kept.split()


def distance(a: list, b: list) -> int:
    """Levenshtein distance between two token lists."""
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def error_rate(language: str, reference: str, transcript: str) -> float:
    ref, hyp = units(language, reference), units(language, transcript)
    return distance(ref, hyp) / max(len(ref), 1)


def fixture_error_rate(fixture: dict, transcript: str) -> float:
    """The lowest error rate against a fixture's reference text and its
    accepted variants ("also": numbers written out, a corrected typo).

    >>> f = {"language": "en", "text": "by 25 to 30 year", "also": ["by twenty-five to thirty years"]}
    >>> fixture_error_rate(f, "by twenty five to thirty years")
    0.0
    """
    return min(error_rate(fixture["language"], ref, transcript) for ref in [fixture["text"]] + fixture.get("also", []))


if __name__ == "__main__":
    print(f"{error_rate(sys.argv[1], sys.argv[2], sys.argv[3]):.3f}")
