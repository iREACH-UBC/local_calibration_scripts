#!/usr/bin/env python3
"""
generate_elusive_json.py
------------------------
Reads ALL calibrated CSVs for MOD-00624 from the calibrated data directory,
computes AQHI, and outputs:

  history.geojson  -- GeoJSON FeatureCollection with one Feature per 15-min reading
  latest.json      -- Single JSON object with the most recent reading

Coordinates are fixed until GPS data becomes available.

Usage:
    python generate_elusive_json.py
        --base-dir   C:\\ProgramData\\iREACH\\data\\calibrated
        --output-dir C:\\ProgramData\\iREACH\\elusive_output\\data
"""

from __future__ import annotations
import argparse
import json
import math
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd

SENSOR_ID = "MOD-00624"
LAT       = 49.2526
LON       = -123.2387

PACIFIC = timezone(timedelta(hours=-7))
WANT_COLS = {"date", "co", "no", "no2", "o3", "co2", "pm2.5", "pm2_5"}


def safe_round(val, ndigits: int) -> float | None:
    if pd.isna(val):
        return None
    try:
        v = float(val)
    except (TypeError, ValueError):
        return None
    if v < 0:
        return None
    return round(v, ndigits)


def load_all_csvs(base_dir: Path) -> pd.DataFrame | None:
    sensor_dir = base_dir / SENSOR_ID
    if not sensor_dir.is_dir():
        print(f"[ERROR] {sensor_dir} not found", file=sys.stderr)
        return None

    csvs = sorted(sensor_dir.glob("*.csv"), key=lambda p: p.stat().st_mtime)
    if not csvs:
        print(f"[ERROR] No CSVs in {sensor_dir}", file=sys.stderr)
        return None

    frames = []
    for p in csvs:
        try:
            df = pd.read_csv(p, usecols=lambda c: c.lower() in WANT_COLS)
            frames.append(df)
            print(f"[INFO] Loaded {p.name} ({len(df)} rows)", file=sys.stderr)
        except Exception as e:
            print(f"[WARN] Could not read {p.name}: {e}", file=sys.stderr)

    if not frames:
        return None

    df = pd.concat(frames, ignore_index=True)

    # Normalise columns
    rename = {}
    for c in df.columns:
        cl = c.lower()
        if cl in ("pm2_5", "pm2.5"):
            rename[c] = "PM25"
        elif cl == "date":
            rename[c] = "DATE"
        elif cl in {"co", "no", "no2", "o3", "co2"}:
            rename[c] = c.upper()
    df.rename(columns=rename, inplace=True)

    if "DATE" not in df.columns:
        print("[ERROR] DATE column missing", file=sys.stderr)
        return None

    df["DATE"] = pd.to_datetime(df["DATE"], utc=True, errors="coerce")
    df = df.dropna(subset=["DATE"])
    df.sort_values("DATE", inplace=True)
    df.drop_duplicates(subset=["DATE"], keep="last", inplace=True)
    df.reset_index(drop=True, inplace=True)

    return df


def add_aqhi(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    def _roll(col, window):
        if col not in df.columns:
            return pd.Series(np.nan, index=df.index)
        return pd.to_numeric(df[col], errors="coerce").rolling(window, min_periods=1).mean()

    no2_3h  = _roll("NO2",  12)
    o3_3h   = _roll("O3",   12)
    pm25_3h = _roll("PM25", 12)
    pm25_1h = _roll("PM25",  4)

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


def build_geojson(df: pd.DataFrame) -> dict:
    features = []
    for _, row in df.iterrows():
        ts = row["DATE"].isoformat()
        props = {
            "timestamp": ts,
            "CO":    safe_round(row.get("CO"),   3),
            "NO":    safe_round(row.get("NO"),   3),
            "NO2":   safe_round(row.get("NO2"),  3),
            "O3":    safe_round(row.get("O3"),   3),
            "CO2":   safe_round(row.get("CO2"),  3),
            "PM2_5": safe_round(row.get("PM25"), 3),
            "AQHI":  safe_round(row.get("AQHI"), 1),
        }
        features.append({
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [LON, LAT]
            },
            "properties": props
        })
    return {
        "type": "FeatureCollection",
        "features": features
    }


def build_latest(df: pd.DataFrame) -> dict:
    last = df.iloc[-1]
    return {
        "timestamp": last["DATE"].isoformat(),
        "lat": LAT,
        "lon": LON,
        "pollutants": {
            "CO":    safe_round(last.get("CO"),   3),
            "NO":    safe_round(last.get("NO"),   3),
            "NO2":   safe_round(last.get("NO2"),  3),
            "O3":    safe_round(last.get("O3"),   3),
            "CO2":   safe_round(last.get("CO2"),  3),
            "PM2_5": safe_round(last.get("PM25"), 3),
            "AQHI":  safe_round(last.get("AQHI"), 1),
        }
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-dir",   required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    base_dir   = Path(args.base_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    df = load_all_csvs(base_dir)
    if df is None or df.empty:
        sys.exit("[FATAL] No data loaded for MOD-00624")

    df = add_aqhi(df)

    geojson = build_geojson(df)
    latest  = build_latest(df)

    geojson_path = output_dir / "history.geojson"
    latest_path  = output_dir / "latest.json"

    geojson_path.write_text(json.dumps(geojson, indent=2) + "\n", encoding="utf-8")
    latest_path.write_text(json.dumps(latest, indent=2) + "\n", encoding="utf-8")

    print(f"[SUCCESS] history.geojson written ({len(df)} features)", file=sys.stderr)
    print(f"[SUCCESS] latest.json written (latest: {latest['timestamp']})", file=sys.stderr)
