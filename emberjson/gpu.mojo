"""Public GPU parsing API.

GPU entry points fail loud: on a machine without an accelerator they
raise (`GpuSession()` and every free function) rather than silently
falling back to the CPU engines, and there is no hidden size-threshold
dispatch — callers choose the engine. Crossover guidance lives in each
docstring; the CPU paths (`parse_document`, `is_valid_utf8`, ...) remain
the right choice for small inputs.

`GpuSession` owns the `DeviceContext` and reusable device buffers, so
repeated parses amortize allocation and staging; the free functions are
one-shot conveniences that construct a transient session.

Verdict parity with the CPU engines is a hard contract, enforced by
differential tests and the fuzz oracle.
"""

from ._gpu import GpuSession, NO_ACCELERATOR_ERROR
from ._deserialize.parser import ParseOptions
from .document import Document


def gpu_parse_document[
    options: ParseOptions = ParseOptions(),
    use_gpu_stage2: Bool = False,
](s: StringSlice) raises -> Document:
    """Parses a JSON document on the GPU into the standard `Document`
    (byte-identical to `parse_document`). Raises when no accelerator is
    available — never falls back to the CPU. One-shot convenience:
    constructs a transient `GpuSession`; construct one yourself to reuse
    the device context and buffers across parses.
    """
    var session = GpuSession()
    return session.parse_document[options, use_gpu_stage2](s)


def try_gpu_parse_document[
    options: ParseOptions = ParseOptions()
](s: StringSlice) -> Optional[Document]:
    """`gpu_parse_document` returning `None` on any failure (invalid
    JSON, invalid UTF-8, or no accelerator)."""
    try:
        return gpu_parse_document[options](s)
    except:
        return None


def gpu_parse_documents[
    options: ParseOptions = ParseOptions(),
    use_gpu_stage2: Bool = False,
](s: StringSlice) raises -> List[Document]:
    """Parses JSON Lines text on the GPU: one `Document` per line, with
    `read_lines` semantics (blank and malformed lines silently skipped).
    Raises when no accelerator is available. One-shot convenience:
    constructs a transient `GpuSession`; construct one yourself to reuse
    the device context and buffers across batches.
    """
    var session = GpuSession()
    return session.parse_documents[options, use_gpu_stage2](s)


def gpu_is_valid_utf8(s: StringSlice) raises -> Bool:
    """Validates `s` as UTF-8 (RFC 3629) on the GPU.

    Verdict-identical to `is_valid_utf8`. Raises when no accelerator is
    available. One-shot convenience: constructs a transient `GpuSession`
    (context + buffer setup each call) — construct a session yourself for
    repeated validation.
    """
    var session = GpuSession()
    return session.is_valid_utf8(s)
