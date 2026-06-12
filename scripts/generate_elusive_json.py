#!/usr/bin/env python3
"""
generate_elusive_json.py
------------------------
Standalone pipeline for MOD-00624 (Elusive mobile sensor):

1. Read ALL raw QAQ CSVs for MOD-00624
2. Resample to 5-min averages
3. Calibrate via subprocess call to QAQ_apply_calibration.R
4. Fetch most recent Notehub data.qo events for GPS coordinates
5. Match each reading to nearest Notehub event by Unix timestamp
6. Include T and RH in output
7. Write history.geojson and latest.json

Usage:
    python generate_elusive_json.py
        --raw-dir      C:\\ProgramData\\iREACH\\data\\raw\\MOD-00624
        --scripts-dir  C:\\ProgramData\\iREACH\\scripts
        --cal-obj-dir  C:\\ProgramData\\iREACH\\calibration_objects
        --output-dir   C:\\ProgramData\\iREACH\\elusive_output\\data
        --rscript      "C:\\Program Files\\R\\R-4.5.3\\bin\\Rscript.exe"
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

SENSOR_ID        = "MOD-00624"
DEFAULT_LAT      = 49.2526
DEFAULT_LON      = -123.2387
AVG_TIME         = "5min"

NOTEHUB_PROJECT  = "app:81cfa928-3ec1-4858-9c2b-b41cc8b3d34d"
NOTEHUB_BASE     = "https://api.notefile.net/v1"
NOTEHUB_PAGESIZE = 100

WANT_COLS = {"date", "co", "no", "no2", "o3", "co2", "t", "rh", "pm2.5", "pm2_5"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def safe_round(val, ndigits: int):
    if val is None:
        return None
    try:
        v = float(val)
    except (TypeError, ValueError):
        return None
    if math.isnan(v):
        return None
    return round(v, ndigits)


def add_aqhi(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    def _roll(col, window):
        if col not in df.columns:
            return pd.Series(np.nan, index=df.index)
        return pd.to_numeric(df[col], errors="coerce").rolling(window, min_periods=1).mean()

    # 5-min data: 3h = 36 periods, 1h = 12 periods
    no2_3h  = _roll("NO2",  36)
    o3_3h   = _roll("O3",   36)
    pm25_col = "PM25" if "PM25" in df.columns else "PM2_5"
    pm25_3h = _roll(pm25_col, 36)
    pm25_1h = _roll(pm25_col, 12)

    no2_c  = np.exp(0.000871 * no2_3h)  - 1
    o3_c   = np.exp(0.000537 * o3_3h)   - 1
    pm25_c = np.exp(0.000487 * pm25_3h) - 1

    aqhi_raw = (10 / 10.4) * 100 * (no2_c + o3_c + pm25_c)

    def _ceiling(a, p):
        if pd.isna(a):
            return None
        base = int(round(float(a)))
        if pd.notna(p):
            base = max(base, math.ceil(float(p) / 10))
        return max(base, 1)

    df["AQHI"] = [_ceiling(a, p) for a, p in zip(aqhi_raw, pm25_1h)]
    return df


# ---------------------------------------------------------------------------
# Step 1: Load and resample raw QAQ data
# ---------------------------------------------------------------------------

def load_and_resample_raw(raw_dir: Path) -> pd.DataFrame | None:
    csvs = sorted(raw_dir.glob("*.csv"), key=lambda p: p.stat().st_mtime)
    if not csvs:
        print(f"[ERROR] No raw CSVs in {raw_dir}", file=sys.stderr)
        return None

    frames = []
    for p in csvs:
        try:
            df = pd.read_csv(p, low_memory=False)
            # Normalise column names
            df.columns = [c.strip() for c in df.columns]
            frames.append(df)
            print(f"[INFO] Loaded raw {p.name} ({len(df)} rows)", file=sys.stderr)
        except Exception as e:
            print(f"[WARN] Could not read {p.name}: {e}", file=sys.stderr)

    if not frames:
        return None

    df = pd.concat(frames, ignore_index=True)

    # Find timestamp column
    ts_col = next((c for c in df.columns if c.lower() == "timestamp"), None)
    if ts_col is None:
        print("[ERROR] No timestamp column in raw data", file=sys.stderr)
        return None

    df["_ts"] = pd.to_datetime(df[ts_col], utc=True, errors="coerce")
    df = df.dropna(subset=["_ts"]).sort_values("_ts")
    df = df.set_index("_ts")

    # Map columns to standard names
    col_map = {}
    for c in df.columns:
        cl = c.lower().strip()
        if cl == "co":                              col_map[c] = "CO"
        elif cl == "no2":                           col_map[c] = "NO2"
        elif cl == "no":                            col_map[c] = "NO"
        elif cl == "o3":                            col_map[c] = "O3"
        elif cl == "co2":                           col_map[c] = "CO2"
        elif cl in ("pm25", "pm2.5", "pm2_5"):     col_map[c] = "PM2.5"
        elif cl == "pm1":                           col_map[c] = "PM1"
        elif cl == "pm10":                          col_map[c] = "PM10"
        elif cl in ("temp", "temperature", "t"):   col_map[c] = "T"
        elif cl in ("rh", "humidity"):              col_map[c] = "RH"
    df = df.rename(columns=col_map)

    needed = ["CO", "NO", "NO2", "O3", "CO2", "T", "RH", "PM2.5", "PM1", "PM10"]
    missing = [c for c in needed if c not in df.columns]
    if missing:
        print(f"[WARN] Missing columns in raw data: {missing}", file=sys.stderr)

    # Resample to 5-min averages
    numeric_cols = [c for c in ["CO", "NO", "NO2", "O3", "CO2", "T", "RH", "PM2.5", "PM1", "PM10"] if c in df.columns]
    resampled = df[numeric_cols].resample(AVG_TIME).mean()
    resampled = resampled.dropna(how="all")
    resampled = resampled.reset_index().rename(columns={"_ts": "DATE"})

    # Format DATE as the calibration script expects: MM/DD/YYYY HH:MM
    resampled["DATE"] = resampled["DATE"].dt.strftime("%m/%d/%Y %H:%M")

    print(f"[INFO] Resampled to {len(resampled)} 5-min rows", file=sys.stderr)
    return resampled


# ---------------------------------------------------------------------------
# Step 2: Calibrate via R subprocess
# ---------------------------------------------------------------------------

def calibrate(df: pd.DataFrame, scripts_dir: Path, cal_obj_dir: Path,
               rscript_exe: str) -> pd.DataFrame | None:

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Write downsampled CSV
        in_dir = tmpdir / "downsampled" / SENSOR_ID
        in_dir.mkdir(parents=True)
        in_csv = in_dir / f"elusive_5min_{SENSOR_ID}.csv"
        df.to_csv(in_csv, index=False)

        out_dir = tmpdir / "calibrated"
        out_dir.mkdir()

        caps_core  = (scripts_dir / "caps_core.R").as_posix().replace("\\", "/")
        scripts_p  = scripts_dir.as_posix().replace("\\", "/")
        cal_obj_p  = cal_obj_dir.as_posix().replace("\\", "/")
        in_root_p  = (tmpdir / "downsampled").as_posix().replace("\\", "/")
        out_root_p = out_dir.as_posix().replace("\\", "/")

        r_script = f"""
options(pipeline.sourced = TRUE)
source('{scripts_p}/QAQ_apply_calibration.R')
qaq_apply_general_calibration(
  sensor_ids        = c('{SENSOR_ID}'),
  generalized_model = FALSE,
  models_root       = '{cal_obj_p}',
  in_root           = '{in_root_p}',
  out_root          = '{out_root_p}',
  caps_core_path    = '{caps_core}',
  tz_in             = 'UTC',
  tz_out            = 'UTC',
  verbose           = TRUE
)
"""
        r_file = tmpdir / "elusive_cal.R"
        r_file.write_text(r_script, encoding="ascii")

        result = subprocess.run(
            [rscript_exe, str(r_file)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"[ERROR] R calibration failed:\n{result.stderr}", file=sys.stderr)
            return None

        # Find output CSV
        pred_csvs = list((out_dir / SENSOR_ID).glob("*_pred.csv"))
        if not pred_csvs:
            print("[ERROR] No calibrated output CSV found", file=sys.stderr)
            return None

        cal_df = pd.read_csv(pred_csvs[0])

        # Also bring T and RH from the input (not output by calibration)
        cal_df["DATE"] = pd.to_datetime(cal_df["DATE"], utc=True, errors="coerce")

        # R drops T, RH, PM1, PM10 from output — add them back by position
        # (resampled input and calibrated output have same rows in same order)
        extra_cols = [c for c in ["T", "RH", "PM1", "PM10"] if c in df.columns]
        for col in extra_cols:
            cal_df[col] = df[col].values

        cal_df = cal_df.dropna(subset=["DATE"]).sort_values("DATE").reset_index(drop=True)
        print(f"[INFO] Calibrated {len(cal_df)} rows", file=sys.stderr)
        return cal_df


# ---------------------------------------------------------------------------
# Step 3: Fetch Notehub coordinates
# ---------------------------------------------------------------------------

def fetch_notehub_coords(token: str) -> list[dict]:
    """Fetch most recent page of data.qo events and extract coordinates + unix timestamp."""
    url = (
        f"{NOTEHUB_BASE}/projects/{NOTEHUB_PROJECT}/events"
        f"?files=data.qo&sortBy=captured&sortOrder=desc&pageSize={NOTEHUB_PAGESIZE}"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"[WARN] Notehub fetch failed: {e}", file=sys.stderr)
        return []

    events = data.get("events", [])
    coords = []
    for ev in events:
        when = ev.get("when")
        if when is None:
            continue
        body = ev.get("body", {}) or {}
        lat = body.get("Latitude")
        lon = body.get("Longitude")

        valid_body = (
            lat is not None and lon is not None
            and lat != 0 and lon != 0
            and -90 <= lat <= 90 and -180 <= lon <= 180
        )
        if valid_body:
            coords.append({"unix": float(when), "lat": lat, "lon": lon, "source": "body"})
        else:
            best_lat = ev.get("best_lat")
            best_lon = ev.get("best_lon")
            valid_best = (
                best_lat is not None and best_lon is not None
                and best_lat != 0 and best_lon != 0
                and -90 <= best_lat <= 90 and -180 <= best_lon <= 180
            )
            if valid_best:
                coords.append({"unix": float(when), "lat": best_lat, "lon": best_lon, "source": "notehub_best"})

    print(f"[INFO] Fetched {len(coords)} Notehub coordinate records", file=sys.stderr)
    return coords


def fetch_notehub_coords_all(token: str, start_unix: float = None, pages: int = 30) -> list[dict]:
    """Fetch Notehub coords for backfill using time-bounded pages with retry on 429."""
    import time
    all_coords = []
    cursor = None

    # Build base URL — filter by startDate if provided to skip irrelevant old events
    base = (
        f"{NOTEHUB_BASE}/projects/{NOTEHUB_PROJECT}/events"
        f"?files=data.qo&sortBy=captured&sortOrder=asc&pageSize={NOTEHUB_PAGESIZE}"
    )
    if start_unix is not None:
        # Notehub startDate expects Unix seconds as integer
        base += f"&startDate={int(start_unix)}"

    for page_num in range(pages):
        url = base if cursor is None else base + f"&cursor={cursor}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        attempt = 0
        data = None
        while attempt < 5:
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read())
                break
            except Exception as e:
                if "429" in str(e):
                    wait = 5 * (attempt + 1)
                    print(f"[WARN] Notehub 429 on page {page_num+1}, retrying in {wait}s...", file=sys.stderr)
                    time.sleep(wait)
                    attempt += 1
                else:
                    print(f"[WARN] Notehub page fetch failed: {e}", file=sys.stderr)
                    break
        if data is None:
            break

        events = data.get("events", [])
        if not events:
            break
        for ev in events:
            when = ev.get("when")
            if when is None:
                continue
            body = ev.get("body", {}) or {}
            lat = body.get("Latitude")
            lon = body.get("Longitude")
            valid_body = (
                lat is not None and lon is not None
                and lat != 0 and lon != 0
                and -90 <= lat <= 90 and -180 <= lon <= 180
            )
            if valid_body:
                all_coords.append({"unix": float(when), "lat": lat, "lon": lon, "source": "body"})
            else:
                best_lat = ev.get("best_lat")
                best_lon = ev.get("best_lon")
                valid_best = (
                    best_lat is not None and best_lon is not None
                    and best_lat != 0 and best_lon != 0
                    and -90 <= best_lat <= 90 and -180 <= best_lon <= 180
                )
                if valid_best:
                    all_coords.append({"unix": float(when), "lat": best_lat, "lon": best_lon, "source": "notehub_best"})
        cursor = data.get("through")
        has_more = data.get("has_more", False)
        print(f"[INFO] Page {page_num+1}: {len(events)} events, total coords so far: {len(all_coords)}", file=sys.stderr)
        if not has_more or not cursor:
            break
        time.sleep(1)  # gentle pacing between pages

    print(f"[INFO] Fetched {len(all_coords)} Notehub coordinate records (backfill)", file=sys.stderr)
    return all_coords


def match_coords(unix_ts: float, notehub_coords: list[dict]) -> tuple[float, float]:
    """Return (lat, lon) of nearest Notehub event by Unix timestamp."""
    if not notehub_coords:
        return DEFAULT_LAT, DEFAULT_LON
    nearest = min(notehub_coords, key=lambda c: abs(c["unix"] - unix_ts))
    return nearest["lat"], nearest["lon"]


# ---------------------------------------------------------------------------
# Step 4: Build GeoJSON and latest.json
# ---------------------------------------------------------------------------

def build_geojson(df: pd.DataFrame, notehub_coords: list[dict]) -> dict:
    features = []
    for _, row in df.iterrows():
        unix_ts = row["DATE"].timestamp()
        lat, lon = match_coords(unix_ts, notehub_coords)
        ts = row["DATE"].isoformat()

        props = {
            "timestamp": ts,
            "CO":    safe_round(row.get("CO"),    3),
            "NO":    safe_round(row.get("NO"),    3),
            "NO2":   safe_round(row.get("NO2"),   3),
            "O3":    safe_round(row.get("O3"),    3),
            "CO2":   safe_round(row.get("CO2"),   3),
            "PM2_5": safe_round(row.get("PM2_5"), 3),
            "PM1":   safe_round(row.get("PM1"),   3),
            "PM10":  safe_round(row.get("PM10"),  3),
            "T":     safe_round(row.get("T"),     2),
            "RH":    safe_round(row.get("RH"),    2),
            "AQHI":  safe_round(row.get("AQHI"),  1),
        }
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": props
        })
    return {"type": "FeatureCollection", "features": features}


def build_latest(df: pd.DataFrame, notehub_coords: list[dict]) -> dict:
    last = df.iloc[-1]
    unix_ts = last["DATE"].timestamp()
    lat, lon = match_coords(unix_ts, notehub_coords)
    return {
        "timestamp": last["DATE"].isoformat(),
        "lat": lat,
        "lon": lon,
        "pollutants": {
            "CO":    safe_round(last.get("CO"),    3),
            "NO":    safe_round(last.get("NO"),    3),
            "NO2":   safe_round(last.get("NO2"),   3),
            "O3":    safe_round(last.get("O3"),    3),
            "CO2":   safe_round(last.get("CO2"),   3),
            "PM2_5": safe_round(last.get("PM2_5"), 3),
            "PM1":   safe_round(last.get("PM1"),   3),
            "PM10":  safe_round(last.get("PM10"),  3),
            "T":     safe_round(last.get("T"),     2),
            "RH":    safe_round(last.get("RH"),    2),
            "AQHI":  safe_round(last.get("AQHI"),  1),
        }
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-dir",     required=True)
    parser.add_argument("--scripts-dir", required=True)
    parser.add_argument("--cal-obj-dir", required=True)
    parser.add_argument("--output-dir",  required=True)
    parser.add_argument("--rscript",          default="C:\\Program Files\\R\\R-4.5.3\\bin\\Rscript.exe")
    parser.add_argument("--backfill-coords",  action="store_true",
                        help="Re-fetch all Notehub coords and update history.geojson coordinates without reprocessing raw data")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    geojson_path = output_dir / "history.geojson"
    latest_path  = output_dir / "latest.json"

    token = os.environ.get("NOTEHUB_TOKEN", "")

    # ------------------------------------------------------------------
    # Backfill-coords mode: update coords in existing history without
    # reprocessing raw data.
    # ------------------------------------------------------------------
    if args.backfill_coords:
        if not token:
            sys.exit("[FATAL] --backfill-coords requires NOTEHUB_TOKEN to be set")
        if not geojson_path.exists():
            sys.exit("[FATAL] No history.geojson found to backfill")

        print("[INFO] Backfill-coords mode: fetching full Notehub history...", file=sys.stderr)
        # Start from the earliest timestamp in history minus a small buffer
        existing_check = json.loads(geojson_path.read_text(encoding="utf-8"))
        first_ts = existing_check.get("features", [{}])[0].get("properties", {}).get("timestamp")
        start_unix = None
        if first_ts:
            try:
                import pandas as _pd
                start_unix = _pd.Timestamp(first_ts).timestamp() - 3600
            except Exception:
                pass
        all_coords = fetch_notehub_coords_all(token, start_unix=start_unix, pages=30)
        if not all_coords:
            sys.exit("[FATAL] No Notehub coordinates fetched")

        existing = json.loads(geojson_path.read_text(encoding="utf-8"))
        features = existing.get("features", [])
        print(f"[INFO] Updating coordinates for {len(features)} features...", file=sys.stderr)

        default_coords = {DEFAULT_LAT, (DEFAULT_LAT, DEFAULT_LON)}
        updated = 0
        for f in features:
            ts = f.get("properties", {}).get("timestamp")
            if not ts:
                continue
            try:
                unix_ts = pd.Timestamp(ts).timestamp()
            except Exception:
                continue
            lat, lon = match_coords(unix_ts, all_coords)
            # Only update if coords changed
            old_coords = f["geometry"]["coordinates"]
            if old_coords != [lon, lat]:
                f["geometry"]["coordinates"] = [lon, lat]
                updated += 1

        geojson_path.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
        print(f"[SUCCESS] Backfill complete — updated {updated}/{len(features)} feature coordinates", file=sys.stderr)
        sys.exit(0)

    # ------------------------------------------------------------------
    # Normal pipeline mode
    # ------------------------------------------------------------------
    raw_dir     = Path(args.raw_dir)
    scripts_dir = Path(args.scripts_dir)
    cal_obj_dir = Path(args.cal_obj_dir)

    # Load and resample
    df_raw = load_and_resample_raw(raw_dir)
    if df_raw is None or df_raw.empty:
        sys.exit("[FATAL] No raw data loaded for MOD-00624")

    # Calibrate
    df_cal = calibrate(df_raw, scripts_dir, cal_obj_dir, args.rscript)
    if df_cal is None or df_cal.empty:
        sys.exit("[FATAL] Calibration failed")

    # Normalise PM column name
    if "PM2_5" not in df_cal.columns and "PM2.5" in df_cal.columns:
        df_cal = df_cal.rename(columns={"PM2.5": "PM2_5"})

    # AQHI
    df_cal = add_aqhi(df_cal)

    # Notehub coordinates
    if token:
        notehub_coords = fetch_notehub_coords(token)
    else:
        print("[WARN] NOTEHUB_TOKEN not set — using default coordinates", file=sys.stderr)
        notehub_coords = []

    # Build new features from current calibrated data
    new_geojson = build_geojson(df_cal, notehub_coords)
    latest      = build_latest(df_cal, notehub_coords)

    # Load existing history.geojson and merge, deduplicating by timestamp.
    # Preserve existing coordinates — only overwrite pollutant values for
    # timestamps that already exist in history.
    if geojson_path.exists():
        try:
            existing = json.loads(geojson_path.read_text(encoding="utf-8"))
            existing_features = existing.get("features", [])
            print(f"[INFO] Loaded {len(existing_features)} existing features", file=sys.stderr)
        except Exception as e:
            print(f"[WARN] Could not load existing history.geojson: {e}", file=sys.stderr)
            existing_features = []
    else:
        existing_features = []

    # Index existing features by timestamp
    feature_map = {}
    for f in existing_features:
        ts = f.get("properties", {}).get("timestamp")
        if ts:
            feature_map[ts] = f

    # Merge new features: preserve existing coords, only update pollutants
    for f in new_geojson["features"]:
        ts = f.get("properties", {}).get("timestamp")
        if not ts:
            continue
        if ts in feature_map:
            # Timestamp already in history — update pollutants but keep coords
            existing_coords = feature_map[ts]["geometry"]["coordinates"]
            feature_map[ts] = f
            feature_map[ts]["geometry"]["coordinates"] = existing_coords
        else:
            # New timestamp — add with fresh coords from Notehub
            feature_map[ts] = f

    merged_features = sorted(feature_map.values(),
                             key=lambda f: f["properties"]["timestamp"])
    merged_geojson = {"type": "FeatureCollection", "features": merged_features}

    geojson_path.write_text(json.dumps(merged_geojson, indent=2) + "\n", encoding="utf-8")
    latest_path.write_text(json.dumps(latest, indent=2) + "\n", encoding="utf-8")

    print(f"[SUCCESS] history.geojson written ({len(merged_features)} total features)", file=sys.stderr)
    print(f"[SUCCESS] latest.json written (latest: {latest['timestamp']})", file=sys.stderr)
