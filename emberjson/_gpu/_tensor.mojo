"""Typed device-memory views for the GPU kernels.

Kernels take `TileTensor` views rather than bare `UnsafePointer`s, so each
buffer carries its own extent across the launch boundary: a bounds check
reads `t.layout.size()` instead of a separately-passed count that can
drift out of sync with the allocation it describes.

Every scratch buffer in the parser is a flat, runtime-length, 1-D array,
so they all share one layout type — `RowMajorLayout[Int]`, a single
dynamic extent. `Vec[dtype]` names that view and `vec(buf, n)` builds one
over the first `n` elements of a device allocation.

Views are deliberately *logical*-sized. Session buffers are grown
geometrically and reused across parses, so each launch builds a view over
just the region that batch uses rather than over the whole capacity; the
extent a kernel sees is the extent it is allowed to touch.
"""

from layout import RowMajorLayout, TileTensor, row_major
from std.gpu.host import DeviceBuffer

comptime Vec[dt: DType] = TileTensor[dt, RowMajorLayout[Int], MutAnyOrigin]


@always_inline
def vec[dt: DType](mut buf: DeviceBuffer[dt], n: Int) -> Vec[dt]:
    """A view over the first `n` elements of `buf`."""
    return TileTensor(buf, row_major(n))
