"""
upload_to_r2.py
---------------
Uploads calibrated CSVs to Cloudflare R2 in two structures:

  monthly/  <sensor_id>/<sensor_id>_<YYYY>_<MM>.csv
      One file per sensor per month containing ALL rows for that month.
      Existing R2 data is downloaded and MERGED with new rows before
      re-uploading, so the live pipeline's 48-hour window never
      overwrites historical data.

  daily/  <sensor_id>/  <YYYY-MM>/  <sensor_id>_<YYYY>_<MM>_<DD>.csv
      One file per sensor per day (overwrite is safe; each file covers
      exactly one day and only recent days are ever re-processed).

The script reads the calibrated CSVs, parses their DATE column,
and splits them into daily and monthly files before uploading.

Credentials from environment variables:
    R2_ACCESS_KEY_ID
    R2_SECRET_ACCESS_KEY

Usage:
    python upload_to_r2.py
        --calibrated-dir  C:\\ProgramData\\iREACH\\data\\calibrated
        --publish-dir     C:\\ProgramData\\iREACH\\data\\publish
        --bucket          lcs-calibrated-data
        --endpoint        https://<ACCOUNT_ID>.r2.cloudflarestorage.com
        --month           2026-04
"""

import argparse
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:
    print("ERROR: boto3 is not installed.  Run:  pip install boto3")
    sys.exit(1)


# ---------------------------------------------------------------------------
# R2 client
# ---------------------------------------------------------------------------

def get_r2_client(endpoint: str):
    access_key = os.environ.get("R2_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not access_key or not secret_key:
        print("ERROR: R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be set.")
        sys.exit(1)
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
    )


def upload_file(client, local_path: Path, bucket: str, key: str) -> bool:
    try:
        client.upload_file(str(local_path), bucket, key)
        print(f"  OK  {key}")
        return True
    except (BotoCoreError, ClientError) as e:
        print(f"  FAIL {key}: {e}")
        return False


# ---------------------------------------------------------------------------
# R2 download helper (for merge)
# ---------------------------------------------------------------------------

def download_existing_monthly(client, bucket: str, key: str) -> pd.DataFrame | None:
    """
    Download the existing monthly CSV from R2 and return it as a DataFrame
    with DATE parsed as UTC-aware timestamps.

    Returns None if the object does not exist yet (first upload for this month).
    Raises on any other error so the caller can decide whether to abort.
    """
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".csv")
    os.close(tmp_fd)
    try:
        client.download_file(bucket, key, tmp_path)
        df = pd.read_csv(tmp_path)
        if df.empty:
            return None
        # Normalise the DATE column to UTC-aware timestamps
        date_col = next((c for c in df.columns if c.upper() == "DATE"), None)
        if date_col:
            df[date_col] = pd.to_datetime(df[date_col], utc=True, errors="coerce")
            df = df.dropna(subset=[date_col])
            if date_col != "DATE":
                df = df.rename(columns={date_col: "DATE"})
        return df if not df.empty else None
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code in ("404", "NoSuchKey"):
            return None          # object does not exist yet — that's fine
        raise                    # unexpected error — propagate
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Date filtering
# ---------------------------------------------------------------------------

DATE_SPAN = re.compile(r'(\d{4}-\d{2}-\d{2})_to_(\d{4}-\d{2}-\d{2})')


def csvs_for_month(sensor_dir: Path, month: str) -> list[Path]:
    """Return CSVs whose date range overlaps the target month."""
    month_start = datetime.strptime(month + "-01", "%Y-%m-%d").date()
    if month_start.month == 12:
        month_end = month_start.replace(year=month_start.year + 1, month=1, day=1)
    else:
        month_end = month_start.replace(month=month_start.month + 1, day=1)
    month_end = month_end - timedelta(days=1)

    matches = []
    for p in sensor_dir.glob("*.csv"):
        m = DATE_SPAN.search(p.name)
        if m:
            try:
                file_start = datetime.strptime(m.group(1), "%Y-%m-%d").date()
                file_end   = datetime.strptime(m.group(2), "%Y-%m-%d").date()
                if file_start <= month_end and file_end >= month_start:
                    matches.append(p)
            except ValueError:
                pass
        else:
            if month in p.name or month.replace("-", "_") in p.name:
                matches.append(p)
    return sorted(matches)


def load_and_filter_month(csvs: list[Path], month: str) -> pd.DataFrame | None:
    """Load CSVs, parse DATE, keep only rows within the target month."""
    if not csvs:
        return None

    frames = []
    for csv_path in csvs:
        try:
            frames.append(pd.read_csv(csv_path))
        except Exception as e:
            print(f"  WARN: could not read {csv_path.name}: {e}")

    if not frames:
        return None

    df = pd.concat(frames, ignore_index=True)

    # Find DATE column (case-insensitive)
    date_col = next((c for c in df.columns if c.upper() == "DATE"), None)
    if not date_col:
        return df  # no date column, return as-is

    df[date_col] = pd.to_datetime(df[date_col], utc=True, errors="coerce")
    df = df.dropna(subset=[date_col])
    df = df.rename(columns={date_col: "DATE"})

    # Filter to target month
    month_start = datetime.strptime(month + "-01", "%Y-%m-%d")
    if month_start.month == 12:
        month_end = month_start.replace(year=month_start.year + 1, month=1, day=1)
    else:
        month_end = month_start.replace(month=month_start.month + 1, day=1)

    mask = (df["DATE"] >= pd.Timestamp(month_start, tz="UTC")) & \
           (df["DATE"] <  pd.Timestamp(month_end,   tz="UTC"))
    df = df[mask].copy()

    if df.empty:
        return None

    df = df.drop_duplicates(subset=["DATE"]).sort_values("DATE").reset_index(drop=True)
    return df


# ---------------------------------------------------------------------------
# Merge new rows with existing R2 data
# ---------------------------------------------------------------------------

def merge_with_existing(new_df: pd.DataFrame,
                         existing_df: pd.DataFrame | None) -> pd.DataFrame:
    """
    Combine existing R2 data with freshly calibrated rows.

    Strategy:
      - Concatenate existing + new.
      - For any duplicate DATE, keep the NEW row (more recently calibrated).
      - Sort by DATE ascending.

    This means a re-calibration of a past window will always update stored
    values rather than silently being discarded.
    """
    if existing_df is None or existing_df.empty:
        return new_df

    # Tag which frame each row came from so we can prefer new on conflict
    existing_df = existing_df.copy()
    existing_df["_src"] = 0   # older

    new_df = new_df.copy()
    new_df["_src"] = 1         # newer / preferred

    combined = pd.concat([existing_df, new_df], ignore_index=True)

    # Sort so that for duplicate DATEs the new row (src=1) comes last,
    # then keep_last in drop_duplicates retains the new value.
    combined = combined.sort_values(["DATE", "_src"])
    combined = combined.drop_duplicates(subset=["DATE"], keep="last")
    combined = combined.drop(columns=["_src"])
    combined = combined.sort_values("DATE").reset_index(drop=True)

    return combined


# ---------------------------------------------------------------------------
# Build local files
# ---------------------------------------------------------------------------

def build_monthly_file(df: pd.DataFrame, publish_dir: Path,
                        sensor_id: str, month: str) -> Path | None:
    """Write a single monthly CSV: publish/monthly/<sensor_id>/<sensor_id>_<YYYY>_<MM>.csv"""
    year, mon = month.split("-")
    out_dir = publish_dir / "monthly" / sensor_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{sensor_id}_{year}_{mon}.csv"
    try:
        df.to_csv(out_path, index=False)
        return out_path
    except Exception as e:
        print(f"  WARN: could not write monthly file for {sensor_id}: {e}")
        return None


def build_daily_files(df: pd.DataFrame, publish_dir: Path,
                       sensor_id: str, month: str) -> list[Path]:
    """
    Split df by day and write daily CSVs:
        publish/daily/<sensor_id>/<YYYY-MM>/<sensor_id>_<YYYY>_<MM>_<DD>.csv
    Returns list of written file paths.
    """
    year, mon = month.split("-")
    out_dir = publish_dir / "daily" / sensor_id / month
    out_dir.mkdir(parents=True, exist_ok=True)

    written = []
    df = df.copy()
    df["_date"] = df["DATE"].dt.date
    for day, group in df.groupby("_date"):
        day_str = day.strftime("%Y_%m_%d")
        out_path = out_dir / f"{sensor_id}_{day_str}.csv"
        try:
            group.drop(columns=["_date"]).to_csv(out_path, index=False)
            written.append(out_path)
        except Exception as e:
            print(f"  WARN: could not write daily file {out_path.name}: {e}")
    return written


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calibrated-dir", required=True)
    parser.add_argument("--publish-dir",    required=True)
    parser.add_argument("--bucket",         required=True)
    parser.add_argument("--endpoint",       required=True)
    parser.add_argument("--month",          required=True, help="YYYY-MM")
    parser.add_argument("--no-merge",       action="store_true",
                        help="Skip downloading existing R2 data; overwrite monthly file with new rows only")
    args = parser.parse_args()

    calibrated_dir = Path(args.calibrated_dir)
    publish_dir    = Path(args.publish_dir)
    month          = args.month
    year, mon      = month.split("-")

    client   = get_r2_client(args.endpoint)
    uploaded = 0
    failed   = 0

    sensor_dirs = sorted([d for d in calibrated_dir.iterdir() if d.is_dir()])
    if not sensor_dirs:
        print(f"[upload_to_r2] No sensor directories found under {calibrated_dir}")
        sys.exit(1)

    print(f"\n[upload_to_r2] Processing {len(sensor_dirs)} sensors for {month} ...")

    for sensor_dir in sensor_dirs:
        sid  = sensor_dir.name
        csvs = csvs_for_month(sensor_dir, month)

        if not csvs:
            print(f"  SKIP {sid}: no CSVs for {month}")
            continue

        new_df = load_and_filter_month(csvs, month)
        if new_df is None or new_df.empty:
            print(f"  SKIP {sid}: no rows in {month}")
            continue

        print(f"  {sid}: {len(new_df)} new rows")

        # ── Monthly file ──────────────────────────────────────────────────────
        monthly_key = f"monthly/{sid}/{sid}_{year}_{mon}.csv"

        if args.no_merge:
            merged_df = new_df
        else:
            # Download whatever is already in R2 for this sensor/month
            print(f"    Fetching existing R2 data for {monthly_key} ...")
            try:
                existing_df = download_existing_monthly(client, args.bucket, monthly_key)
            except Exception as e:
                print(f"  WARN: could not fetch existing data for {sid}, proceeding with new rows only: {e}")
                existing_df = None

            if existing_df is not None:
                print(f"    Existing rows in R2: {len(existing_df)}")
            else:
                print(f"    No existing data in R2 (first upload for this month)")

            # Merge existing + new, preferring new values on duplicate timestamps
            merged_df = merge_with_existing(new_df, existing_df)
            print(f"    Merged total rows: {len(merged_df)}")

        monthly_path = build_monthly_file(merged_df, publish_dir, sid, month)
        if monthly_path:
            if upload_file(client, monthly_path, args.bucket, monthly_key):
                uploaded += 1
            else:
                failed += 1

        # ── Daily files ───────────────────────────────────────────────────────
        # Daily files cover a single day; overwriting is safe here because
        # the pipeline only re-processes the last 48 hours.
        daily_paths = build_daily_files(merged_df, publish_dir, sid, month)
        for daily_path in daily_paths:
            key = f"daily/{sid}/{month}/{daily_path.name}"
            if upload_file(client, daily_path, args.bucket, key):
                uploaded += 1
            else:
                failed += 1

    print(f"\n[upload_to_r2] Done -- {uploaded} uploaded, {failed} failed.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
