"""
QAQ_download.py

Download QuantAQ (factory-calibrated) data-by-date, one CSV per sensor per day.

File naming + folder structure:
  ../apply_calibrations/apply_calibrations_data/<sensor_id>/<YYYY-MM-DD>_<sensor_id>.csv

Notes
-----
- QuantAQ's data-by-date endpoint uses UTC date boundaries in this context.You are not in UTC, so keep this in mind.
- These are factory-calibrated values; but we add a colocated calibration on top of it. We do this because QAQ specifically 
  has a really neat way of using both an OPC AND a nephelometer to get PM values, so we are making use of this.

Example usage
----------------------------
from QAQ_download import download_qaq_final

download_qaq_final(
    sensor_ids=["MOD-00632", "MOD-0016"... etc.],
    start_date="2025-11-01",
    end_date="2025-12-01",
    output_root="../apply_calibrations/apply_calibrations_data",
    api_key=os.environ["QUANTAQ_API_KEY"],  # get this from quant-aq.com, ask Hugo or Anand for help if you can't find it
)
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional

import pandas as pd
import requests
from requests.auth import HTTPBasicAuth

DEFAULT_API_BASE = "https://api.quant-aq.com/v1"


@dataclass(frozen=True)
class DownloadResult:
    sensor_id: str
    day: date
    rows: int
    out_path: Optional[str]  # None if no data written
    error: Optional[str]     # None if success


def _parse_ymd(d: str) -> date:
    return datetime.strptime(d, "%Y-%m-%d").date()


def _default_output_root() -> Path:
    """
    Resolve output root to:
      ../apply_calibrations/apply_calibrations_data

    This avoids dependence on the current working directory.
    """
    # parents[0] = folder containing this file
    # parents[1] = one level up
    # parents[2] = two levels up, depending on where you have saved this file. I'm 1 level up, and that is what the github will work with.
    return (Path(__file__).resolve().parents[1] / "apply_calibrations" / "apply_calibrations_data").resolve()


def fetch_final_by_date(
    sn: str,
    date_str: str,
    *,
    api_key: str,
    api_base: str = DEFAULT_API_BASE,
    timeout: int = 60,
) -> pd.DataFrame:
    """
    Fetch factory-calibrated data for a device and date, walking pagination.
    """
    url = f"{api_base}/devices/{sn}/data-by-date/{date_str}/"

    all_rows: list[dict] = []
    while url:
        r = requests.get(
            url,
            auth=HTTPBasicAuth(api_key, ""),
            headers={"Accept": "application/json"},
            timeout=timeout,
        )
        if r.status_code != 200:
            raise RuntimeError(f"{r.status_code} {r.text}")

        payload = r.json() or {}
        data = payload.get("data", [])
        if data:
            all_rows.extend(data)

        meta = payload.get("meta", {}) or {}
        next_url = meta.get("next_url") or meta.get("next")
        url = next_url if next_url else None

    return pd.DataFrame(all_rows) if all_rows else pd.DataFrame()


def download_qaq_final(
    *,
    sensor_ids: Iterable[str],
    start_date: str,
    end_date: str,
    output_root: str | os.PathLike | None = None,
    api_key: Optional[str] = None,
    api_base: str = DEFAULT_API_BASE,
    overwrite: bool = True,
    timeout: int = 60,
    verbose: bool = True,
) -> list[DownloadResult]:

    if api_key is None:
        api_key = os.environ.get("QUANTAQ_API_KEY")
    if not api_key:
        raise ValueError("QuantAQ API key not provided. Pass api_key=... or set env var QUANTAQ_API_KEY.")

    sd = _parse_ymd(start_date)
    ed = _parse_ymd(end_date)
    if sd > ed:
        raise ValueError("start_date must be before or equal to end_date (YYYY-MM-DD).")

    root = Path(output_root).expanduser().resolve() if output_root else _default_output_root()
    root.mkdir(parents=True, exist_ok=True)

    results: list[DownloadResult] = []
    sensor_ids_list = list(sensor_ids)

    day = sd
    while day <= ed:
        day_str = day.isoformat()
        if verbose:
            print(f"\nFetching QuantAQ FINAL data for {day_str} ({len(sensor_ids_list)} sensors)")

        for sn in sensor_ids_list:
            sensor_dir = root / sn
            sensor_dir.mkdir(parents=True, exist_ok=True)

            out_path = sensor_dir / f"{day_str}_{sn}.csv"  # <- requested format

            if (not overwrite) and out_path.exists():
                if verbose:
                    print(f"  → {sn} {day_str} (exists; skipped)")
                results.append(DownloadResult(sn, day, rows=0, out_path=str(out_path), error=None))
                continue

            try:
                if verbose:
                    print(f"  → {sn} {day_str}")
                df = fetch_final_by_date(
                    sn,
                    day_str,
                    api_key=api_key,
                    api_base=api_base,
                    timeout=timeout,
                )

                if df.empty:
                    if verbose:
                        print("    No data")
                    results.append(DownloadResult(sn, day, rows=0, out_path=None, error=None))
                    continue

                df.to_csv(out_path, index=False)
                if verbose:
                    print(f"    Saved {len(df)} rows → {out_path}")
                results.append(DownloadResult(sn, day, rows=len(df), out_path=str(out_path), error=None))

            except Exception as e:
                if verbose:
                    print(f"    Error: {e}")
                results.append(DownloadResult(sn, day, rows=0, out_path=None, error=str(e)))

        day += timedelta(days=1)

    return results


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Download QuantAQ FINAL data-by-date to CSV.")
    p.add_argument("--sensors", nargs="+", required=True, help="Sensor IDs, e.g. MOD-00632 MOD-0016")
    p.add_argument("--start", required=True, help="Start date YYYY-MM-DD (inclusive)")
    p.add_argument("--end", required=True, help="End date YYYY-MM-DD (inclusive)")
    p.add_argument(
        "--out-root",
        default=None,
        help=(
            "Output root directory. If omitted, defaults to: "
            "<one-level-up-from-this-file>/apply_calibrations/apply_calibrations_data"
        ),
    )
    p.add_argument("--api-key", default=None, help="QuantAQ API key (or set QUANTAQ_API_KEY env var)")
    p.add_argument("--api-base", default=DEFAULT_API_BASE, help="API base URL")
    p.add_argument("--no-overwrite", action="store_true", help="Do not overwrite existing CSVs")
    p.add_argument("--quiet", action="store_true", help="Less console output")
    args = p.parse_args()

    download_qaq_final(
        sensor_ids=args.sensors,
        start_date=args.start,
        end_date=args.end,
        output_root=args.out_root,
        api_key=args.api_key,
        api_base=args.api_base,
        overwrite=not args.no_overwrite,
        verbose=not args.quiet,
    )
