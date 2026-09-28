"""SIMD structural indexer (simdjson stage 1: Langdale & Lemire, arXiv:1902.08318).

Produces the byte offsets of every structural character in a JSON
document ahead of parsing, letting the parser jump token-to-token instead
of scanning bytes. See `indexer.mojo` for the entry point.
"""

from .indexer import (
    structural_index,
    structural_index_with_flags,
    structural_index_into,
    INDEX_HAS_BACKSLASH,
    INDEX_SLACK,
)
