"""
RAMP_download.py

Download RAMP raw data-by-date, one CSV per sensor per day.

File naming + folder structure:
  ../apply_calibrations/apply_calibrations_data/<sensor_id>/<YYYY-MM-DD>_<sensor_id>.csv

Notes
-----
- RAMP endpoint returns a text format with interleaved name,value tokens per row.
- No API key required for this endpoint.
- The endpoint is not schema-stable: some rows can have missing or extra name/value pairs.
  This downloader parses each row by key (name) rather than relying on fixed column counts.

Example usage
-------------
from RAMP_download import download_ramp_raw

download_ramp_raw(
    sensor_ids=["2021", "2040"],
    start_date="2025-11-01",
    end_date="2025-12-01",
    output_root="../apply_calibrations/apply_calibrations_data",
)
"""

from __future__ import annotations

import csv
import io
import os
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional, Tuple, List

import pandas as pd
import requests


DEFAULT_RAMP_BASE_URL = "http://18.222.146.48/RAMP/v1/raw"


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
    return (Path(__file__).resolve().parents[1] / "apply_calibrations" / "apply_calibrations_data").resolve()


def _dedupe(names: List[str]) -> List[str]:
    """
    Ensure unique column names for pandas; duplicates get suffixed:
      X, X -> X, X__1 (and so on)
    """
    seen: dict[str, int] = {}
    out: List[str] = []
    for n in names:
        if n not in seen:
            seen[n] = 0
            out.append(n)
        else:
            seen[n] += 1
            out.append(f"{n}__{seen[n]}")
    return out


def _parse_ramp_file_text(text: str) -> Tuple[List[str], List[List[str]]]:
    """
    Header line: name,value,name,value,...
    Data lines:  name,value,name,value,...

    Robust parsing:
      - Uses csv.reader (safer than split(","))
      - Drops trailing dangling tokens if a line has odd token count
      - Builds each row by {name: value} mapping
      - Aligns output rows to the header keys (missing keys -> "")

    Returns:
      header: list of (deduped) column names
      rows: list of row-lists aligned to header
    """
    reader = csv.reader(io.StringIO(text))
    lines = [row for row in reader if row and any((c or "").strip() for c in row)]
    if not lines:
        return [], []

    header_tokens = [t.strip() for t in lines[0] if t is not None]
    if len(header_tokens) < 2:
        return [], []

    # If header has odd token count, drop last dangling token
    if len(header_tokens) % 2 == 1:
        header_tokens = header_tokens[:-1]

    header_raw = [h.strip() for h in header_tokens[0::2]]
    if not header_raw:
        return [], []

    header_cols = _dedupe(header_raw)

    rows_out: List[List[str]] = []

    for toks_in in lines[1:]:
        toks = [t.strip() for t in toks_in if t is not None]
        if len(toks) < 2:
            continue

        # If odd token count, drop last dangling token
        if len(toks) % 2 == 1:
            toks = toks[:-1]

        names = toks[0::2]
        vals = toks[1::2]

        d: dict[str, str] = {}
        for k, v in zip(names, vals):
            k = (k or "").strip()
            if k:
                d[k] = (v or "").strip()  # last wins if duplicates

        # Align row by header keys (not positional)
        row = [d.get(k, "") for k in header_raw]
        rows_out.append(row)

    return header_cols, rows_out


def fetch_ramp_by_date(
    sensor_id: str,
    date_str: str,
    *,
    session: requests.Session,
    base_url: str = DEFAULT_RAMP_BASE_URL,
    timeout_head: int = 30,
    timeout_get: int = 60,
) -> pd.DataFrame:
    """
    Fetch and parse a single RAMP daily file into a DataFrame.
    Returns empty DataFrame if file does not exist or has no data rows.
    """
    filename = f"{date_str}-{sensor_id}.txt"
    file_url = f"{base_url}/{sensor_id}/data/{filename}"

    # HEAD first to avoid GET cost/noise if file doesn't exist
    try:
        head = session.head(file_url, timeout=timeout_head)
    except requests.RequestException:
        return pd.DataFrame()

    if head.status_code != 200:
        return pd.DataFrame()

    try:
        resp = session.get(file_url, timeout=timeout_get)
    except requests.RequestException:
        return pd.DataFrame()

    if resp.status_code != 200:
        return pd.DataFrame()

    header, rows = _parse_ramp_file_text(resp.text)
    if not header or not rows:
        return pd.DataFrame()

    return pd.DataFrame(rows, columns=header)


def download_ramp_raw(
    *,
    sensor_ids: Iterable[str],
    start_date: str,
    end_date: str,
    output_root: str | os.PathLike | None = None,
    base_url: str = DEFAULT_RAMP_BASE_URL,
    overwrite: bool = True,
    verbose: bool = True,
) -> list[DownloadResult]:
    """
    Download RAMP raw data for each sensor for each day (inclusive), saving one CSV per sensor per day.

    Output structure (matches QAQ):
        {output_root}/{SENSOR_ID}/{YYYY-MM-DD}_{SENSOR_ID}.csv
    """
    sd = _parse_ymd(start_date)
    ed = _parse_ymd(end_date)
    if sd > ed:
        raise ValueError("start_date must be before or equal to end_date (YYYY-MM-DD).")

    root = Path(output_root).expanduser().resolve() if output_root else _default_output_root()
    root.mkdir(parents=True, exist_ok=True)

    sensor_ids_list = [str(s).strip() for s in sensor_ids if str(s).strip()]
    results: list[DownloadResult] = []

    sess = requests.Session()

    day = sd
    while day <= ed:
        day_str = day.isoformat()
        if verbose:
            print(f"\nFetching RAMP raw data for {day_str} ({len(sensor_ids_list)} sensors)")

        for sid in sensor_ids_list:
            sensor_dir = root / sid
            sensor_dir.mkdir(parents=True, exist_ok=True)

            # SAME naming convention as QAQ:
            out_path = sensor_dir / f"{day_str}_{sid}.csv"

            if (not overwrite) and out_path.exists():
                if verbose:
                    print(f"  → {sid} {day_str} (exists; skipped)")
                results.append(DownloadResult(sid, day, rows=0, out_path=str(out_path), error=None))
                continue

            try:
                if verbose:
                    print(f"  → {sid} {day_str}")

                df = fetch_ramp_by_date(
                    sid,
                    day_str,
                    session=sess,
                    base_url=base_url,
                )

                if df.empty:
                    if verbose:
                        print("    No data / file not found")
                    results.append(DownloadResult(sid, day, rows=0, out_path=None, error=None))
                    continue

                df.to_csv(out_path, index=False)
                if verbose:
                    print(f"    Saved {len(df)} rows → {out_path}")
                results.append(DownloadResult(sid, day, rows=len(df), out_path=str(out_path), error=None))

            except Exception as e:
                if verbose:
                    print(f"    Error: {e}")
                results.append(DownloadResult(sid, day, rows=0, out_path=None, error=str(e)))

        day += timedelta(days=1)

    return results


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Download RAMP raw data and save per-sensor daily CSVs.")
    p.add_argument("--sensors", nargs="+", required=True, help="Sensor IDs, e.g. 2021 2040 (or '2021,2040')")
    p.add_argument("--start", required=True, help="Start date YYYY-MM-DD (inclusive)")
    p.add_argument("--end", required=True, help="End date YYYY-MM-DD (inclusive)")
    p.add_argument(
        "--out-root",
        default=None,
        help="Output root (defaults to ../apply_calibrations/apply_calibrations_data)",
    )
    p.add_argument("--base-url", default=DEFAULT_RAMP_BASE_URL, help="Base URL for RAMP API")
    p.add_argument("--no-overwrite", action="store_true", help="Do not overwrite existing CSVs")
    p.add_argument("--quiet", action="store_true", help="Less console output")
    args = p.parse_args()

    # Accept either: --sensors 2021 2040  OR  --sensors "2021,2040"
    if len(args.sensors) == 1 and "," in args.sensors[0]:
        sensor_ids = [s.strip() for s in args.sensors[0].split(",") if s.strip()]
    else:
        sensor_ids = [s.strip() for s in args.sensors if s.strip()]

    download_ramp_raw(
        sensor_ids=sensor_ids,
        start_date=args.start,
        end_date=args.end,
        output_root=args.out_root,
        base_url=args.base_url,
        overwrite=not args.no_overwrite,
        verbose=not args.quiet,
    )
