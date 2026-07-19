"""Private GPU internals for EmberJson's GPU parsing pipeline.

Layout (built up over the GPU phases):
  * `device.mojo` — `GpuSession`: DeviceContext + reusable scratch buffers.
  * `scan.mojo` — segmented exclusive-scan primitives (Phase 2).
  * `stage1.mojo` — segmented structural-index kernels (Phase 2).
  * `utf8.mojo` — segmented UTF-8 validation kernel (Phase 1).

Public surface is re-exported from `emberjson.gpu`.
"""

from .device import GpuSession, NO_ACCELERATOR_ERROR
