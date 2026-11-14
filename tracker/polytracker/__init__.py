"""Polyphonic guitar pitch tracker for SuperCollider."""
import os

# One small matmul per frame: BLAS threading only adds latency and jitter.
for _v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

__version__ = "1.0.0"
