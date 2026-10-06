"""Runtime configuration for the order generator, read from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    return int(value) if value not in (None, "") else default


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    return float(value) if value not in (None, "") else default


@dataclass(frozen=True)
class GeneratorConfig:
    bucket: str = ""
    landing_prefix: str = "landing/orders/"
    rows_min: int = 80
    rows_max: int = 150
    defect_rate: float = 0.08
    # Changing the salt changes every generated file; keep it stable in production.
    seed_salt: str = "a7-orders"

    def __post_init__(self) -> None:
        if self.rows_min < 1 or self.rows_max < self.rows_min:
            raise ValueError(f"invalid row range: {self.rows_min}..{self.rows_max}")
        if not 0.0 <= self.defect_rate <= 0.5:
            raise ValueError(f"defect_rate must be between 0 and 0.5, got {self.defect_rate}")

    @classmethod
    def from_env(cls) -> "GeneratorConfig":
        return cls(
            bucket=os.environ.get("S3_BUCKET", ""),
            landing_prefix=os.environ.get("S3_LANDING_PREFIX", cls.landing_prefix),
            rows_min=_env_int("ROWS_PER_FILE_MIN", cls.rows_min),
            rows_max=_env_int("ROWS_PER_FILE_MAX", cls.rows_max),
            defect_rate=_env_float("DEFECT_RATE", cls.defect_rate),
            seed_salt=os.environ.get("SEED_SALT", cls.seed_salt),
        )
