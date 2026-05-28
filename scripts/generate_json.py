#!/usr/bin/env python3
# generate_json.py
# ---------------------------------------------------------------------------
# * Walk calibrated_data/<sensor_id>/ (flat R output structure)
# * For each ID in SENSORS_WANTED, load the newest CSV
# * Compute AQHI + Top_AQHI_contributor from raw pollutants
# * Keep the last HISTORY_HOURS of data (UTC-7 fixed offset)
# * Emit a dashboard-ready JSON to OUTPUT_JSON
# ---------------------------------------------------------------------------

from __future__ import annotations
import json, re, sys, math
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pandas as pd
import numpy as np
import urllib.request

# ── EDIT ME ────────────────────────────────────────────────────────────────
SENSORS_WANTED: set[str] | None = {
    "2021",      # West Vancouver Memorial Library
    "2040",      # Gillies Bay Library (Texada)
    "2022",      # Powell River Public Library (qathet outdoor)
    "2024",      # Chief Joe Mathias Centre
    "2033",      # Squamish Nation Totem Hall (replaced 2032 on 2026-03-26)
    "2042",      # Pemberton Community Centre
    "2043",      # Whistler Public Library
    "2030",      # Bowen Island (shared: Rec Center + Library)
    "2039",      # Marpole Oakridge Family Place
    "2025",      # Canadian Memorial United Church (shared outdoor)
    "2031",      # Parkgate Library
    "2023",      # Vancouver Central Public Library
    "MOD-00632", # Lions Gate Rec Center
    "MOD-00616", # Pemberton Community Centre
    "MOD-00625", # Evelyne Saller Center
    "MOD-00631", # Capilano Library
    "MOD-00623", # Lynn Valley Library
    "MOD-00628", # Vancouver Central Public Library
    "MOD-00627", # West End Community Center
}

BASE_DIR      = Path("calibrated_data")
META_CSV      = Path("sensor_metadata.csv")
ADVISORY_URL  = "https://raw.githubusercontent.com/iREACH-UBC/CCAS_Dashboard/main/AQAdvisories.json"
HISTORY_HOURS = 24
OUTPUT_JSON   = Path("pollutant_data.json")
# ───────────────────────────────────────────────────────────────────────────

PACIFIC = timezone(timedelta(hours=-7))   # Vancouver: fixed UTC-7, no DST

# Columns we want from the calibrated CSVs (R outputs CO/NO/NO2/O3/CO2/PM2_5)
WANT_COLS = {"date", "co", "no", "no2", "o3", "co2", "pm2.5", "pm2_5"}

OFFLINE_PRIMARY   = "Not Available"
OFFLINE_POLLUTANT = "N/A"


# ── I/O helpers ────────────────────────────────────────────────────────────

def _clean_str(x: Any) -> str | None:
    if isinstance(x, str):
        s = x.strip().lstrip("\ufeff")
        return s or None
    return None


def to_pacific_iso(ts) -> str | None:
    return None if pd.isna(ts) else ts.isoformat(timespec="minutes")


def safe_round(val, ndigits: int, *, allow_negative: bool = False):
    if pd.isna(val):
        return None
    try:
        v = float(val)
    except (TypeError, ValueError):
        return None
    if (not allow_negative) and v < 0:
        return None
    return round(v, ndigits)


# ── Data loading ────────────────────────────────────────────────────────────

def load_sensor_df(sid: str) -> pd.DataFrame | None:
    """
    Load calibrated CSV(s) for sid from BASE_DIR/<sid>/.
    Loads the newest file (R writes one multi-day span per run).
    Returns a normalised DataFrame sorted by DATE, or None.
    """
    sensor_dir = BASE_DIR / sid
    if not sensor_dir.is_dir():
        print(f"[WARN] {sid}: directory not found: {sensor_dir}", file=sys.stderr)
        return None

    all_csvs = sorted(sensor_dir.glob("*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not all_csvs:
        print(f"[WARN] {sid}: no CSVs in {sensor_dir}", file=sys.stderr)
        return None

    frames = []
    for csv_path in all_csvs:
        try:
            df = pd.read_csv(csv_path, usecols=lambda c: c.lower() in WANT_COLS)
            print(f"[INFO] {sid}: loaded {csv_path.name} ({len(df)} rows)", file=sys.stderr)
            frames.append(df)

        except Exception as e:
            print(f"[ERROR] {sid}: {csv_path}: {e}", file=sys.stderr)

    if not frames:
        return None

    df = pd.concat(frames, ignore_index=True)

    # Normalise column names
    df.columns = [c.strip() for c in df.columns]
    # PM2_5 (R output) -> PM25
    rename = {}
    for c in df.columns:
        cl = c.lower()
        if cl == "pm2_5" or cl == "pm2.5":
            rename[c] = "PM25"
        elif cl == "date":
            rename[c] = "DATE"
        elif cl in {"co", "no", "no2", "o3", "co2"}:
            rename[c] = c.upper()
    df.rename(columns=rename, inplace=True)

    if "DATE" not in df.columns:
        print(f"[WARN] {sid}: DATE column missing", file=sys.stderr)
        return None

    # Parse DATE — R writes "MM/DD/YYYY HH:MM" in UTC
    df["DATE"] = pd.to_datetime(df["DATE"], utc=True)
    df["DATE"] = df["DATE"].dt.tz_convert(PACIFIC)

    df.sort_values("DATE", inplace=True)
    df.drop_duplicates(subset=["DATE"], keep="last", inplace=True)
    df.reset_index(drop=True, inplace=True)

    return df


# ── AQHI ────────────────────────────────────────────────────────────────────

def add_aqhi(df: pd.DataFrame) -> pd.DataFrame:
    """
    Compute AQHI + Top_AQHI_contributor on the full dataset (before windowing).
    Uses 3h rolling means (12 × 15-min rows) and 1h PM2.5 (4 rows) for ceiling.
    """
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

    total = no2_c + o3_c + pm25_c

    def _top(n, o, p, t):
        if pd.isna(t) or t == 0:
            return None
        fracs = {k: v for k, v in {"NO2": n/t, "O3": o/t, "PM2.5": p/t}.items() if pd.notna(v)}
        return max(fracs, key=fracs.get) if fracs else None

    df["PRIMARY"] = [_top(n, o, p, t) for n, o, p, t in zip(no2_c, o3_c, pm25_c, total)]

    return df


# ── Metadata + advisories ───────────────────────────────────────────────────

def read_meta(meta_csv: Path) -> dict[str, dict]:
    if not meta_csv.exists():
        print(f"[WARN] metadata file {meta_csv} missing", file=sys.stderr)
        return {}
    df = pd.read_csv(meta_csv, dtype=str, skipinitialspace=True,
                     engine="python", keep_default_na=False)
    df = df.map(_clean_str)
    df["id"] = df["id"].str.replace(r"\.0$", "", regex=True)
    expected = ["id", "lat", "lon", "name", "sensor_number", "region"]
    if len(df.columns) > len(expected):
        region_parts = df.columns[len(expected)-1:]
        df["region"] = (
            df[region_parts].astype(str)
              .apply(lambda row: ", ".join([_clean_str(c) for c in row if _clean_str(c)]), axis=1)
        )
        df = df[expected]
    df = df[~df["id"].duplicated(keep="first")]
    return {str(r.id): r.to_dict() for _, r in df.iterrows()}


def read_advisories() -> dict[str, bool]:
    try:
        with urllib.request.urlopen(ADVISORY_URL, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return {a.get("Region", ""): bool(a.get("ActiveAlert")) for a in data.get("Advisories", [])}
    except Exception as e:
        print(f"[WARN] Could not fetch AQAdvisories.json: {e}", file=sys.stderr)
        return {}


# ── Offline helpers ─────────────────────────────────────────────────────────

def make_offline_history(now_ts: datetime, history_hours: int) -> list:
    if history_hours <= 0:
        return []
    return [
        [to_pacific_iso(now_ts - timedelta(hours=history_hours - 1 - i)),
         None, None, None, None, None, None, None, None]
        for i in range(history_hours)
    ]


def make_offline_sensor(sid, meta, alerts, *, now_ts, history_hours, reason=None):
    m = meta.get(sid, {}) or {}
    region = _clean_str(m.get("region")) or None
    if reason:
        print(f"[WARN] {sid}: marked offline – {reason}", file=sys.stderr)
    return {
        "id":            sid,
        "name":          _clean_str(m.get("name")),
        "sensor_number": _clean_str(m.get("sensor_number")),
        "region":        region,
        "lat":           float(m.get("lat")) if m.get("lat") else None,
        "lon":           float(m.get("lon")) if m.get("lon") else None,
        "active_alert":  alerts.get(region, False),
        "latest": {
            "timestamp": None,
            "aqhi":      None,
            "primary":   OFFLINE_PRIMARY,
            "pollutants": {k: OFFLINE_POLLUTANT for k in ("co","no","no2","o3","co2","pm25")},
        },
        "history": make_offline_history(now_ts, history_hours),
    }


# ── Core builder ────────────────────────────────────────────────────────────

def build() -> dict:
    meta   = read_meta(META_CSV)
    alerts = read_advisories()
    sensors_js = []
    now_ts = datetime.now(PACIFIC).replace(second=0, microsecond=0)

    sensor_ids = sorted(SENSORS_WANTED) if SENSORS_WANTED is not None else sorted(
        p.name for p in BASE_DIR.iterdir() if p.is_dir()
    )

    for sid in sensor_ids:
        try:
            df = load_sensor_df(sid)

            if df is None:
                sensors_js.append(make_offline_sensor(
                    sid, meta, alerts, now_ts=now_ts,
                    history_hours=HISTORY_HOURS, reason="no calibrated CSVs found"))
                continue

            # Compute AQHI on full dataset before windowing
            df = add_aqhi(df)

            full_df = df.copy()

            if HISTORY_HOURS > 0 and not df.empty:
                cutoff = df["DATE"].max() - pd.Timedelta(hours=HISTORY_HOURS)
                df = df[df["DATE"] >= cutoff]

            if df.empty:
                reason = "no rows in CSV" if full_df.empty else f"no rows in last {HISTORY_HOURS}h (stale data suppressed)"
                sensors_js.append(make_offline_sensor(
                    sid, meta, alerts, now_ts=now_ts,
                    history_hours=HISTORY_HOURS, reason=reason))
                continue

            last = df.iloc[-1]
            print(f"[DEBUG] {sid}: Final NO value: {last.get('NO')} → "
                  f"rounded: {round(float(last['NO']), 3) if pd.notna(last.get('NO')) else None}",
                  file=sys.stderr)

            latest = {
                "timestamp": to_pacific_iso(last["DATE"]),
                "aqhi":    safe_round(last.get("AQHI"),  1, allow_negative=False),
                "primary": last.get("PRIMARY") if isinstance(last.get("PRIMARY"), str) else None,
                "pollutants": {
                    "co":   safe_round(last.get("CO"),   3),
                    "no":   safe_round(last.get("NO"),   3),
                    "no2":  safe_round(last.get("NO2"),  3),
                    "o3":   safe_round(last.get("O3"),   3),
                    "co2":  safe_round(last.get("CO2"),  3),
                    "pm25": safe_round(last.get("PM25"), 3),
                },
            }

            history = [
                [
                    to_pacific_iso(r["DATE"]),
                    safe_round(r.get("AQHI"),  1, allow_negative=False),
                    r.get("PRIMARY") if isinstance(r.get("PRIMARY"), str) else None,
                    safe_round(r.get("CO"),   2),
                    safe_round(r.get("NO"),   2),
                    safe_round(r.get("NO2"),  2),
                    safe_round(r.get("O3"),   2),
                    safe_round(r.get("CO2"),  2),
                    safe_round(r.get("PM25"), 2),
                ]
                for _, r in df.iterrows()
            ]

            m = meta.get(sid, {}) or {}
            region = _clean_str(m.get("region")) or None
            sensors_js.append({
                "id":            sid,
                "name":          _clean_str(m.get("name")),
                "sensor_number": _clean_str(m.get("sensor_number")),
                "region":        region,
                "lat":           float(m.get("lat")) if m.get("lat") else None,
                "lon":           float(m.get("lon")) if m.get("lon") else None,
                "active_alert":  alerts.get(region, False),
                "latest":        latest,
                "history":       history,
            })

            print(f"[INFO] {sid}: wrote {len(history)} rows (to {latest['timestamp']}), "
                  f"alert={alerts.get(region, False)}", file=sys.stderr)

        except Exception as e:
            print(f"[ERROR] {sid}: unexpected failure {e!r} → marking offline", file=sys.stderr)
            sensors_js.append(make_offline_sensor(
                sid, meta, alerts, now_ts=now_ts,
                history_hours=HISTORY_HOURS, reason="unexpected exception during build()"))

    return {
        "generated_at": datetime.now(PACIFIC).isoformat(timespec="minutes"),
        "sensors":      sensors_js,
    }


# ── Entry point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-dir",    default=None)
    parser.add_argument("--meta-csv",    default=None)
    parser.add_argument("--output-json", default=None)
    args = parser.parse_args()

    if args.base_dir:
        BASE_DIR = Path(args.base_dir)
    if args.meta_csv:
        META_CSV = Path(args.meta_csv)
    if args.output_json:
        OUTPUT_JSON = Path(args.output_json)

    if not BASE_DIR.is_dir():
        sys.exit(f"[FATAL] {BASE_DIR} is not a directory")

    result = build()
    OUTPUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_JSON.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"[SUCCESS] {OUTPUT_JSON} written ({len(result['sensors'])} sensors)", file=sys.stderr)
