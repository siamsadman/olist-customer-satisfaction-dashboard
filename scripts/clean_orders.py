"""
Portfolio #3 — Customer Experience & Satisfaction
clean_orders.py

Cleans olist_orders_dataset.csv, keeping only the columns needed for
Page 2 (Satisfaction Drivers) — specifically delivery-to-review timing
and on-time/late bucketing.

This is a fresh, self-contained pass for Portfolio #3. Portfolio #2
already fixed the same placeholder-date issue in its own staging table,
but #3 does not depend on #2's database objects — this script applies
the same fix independently, per Portfolio #3's own pipeline.

Known issue this script guards against (per handover notes):
  - The *original* Portfolio #1/#2 cleaning script filled missing
    order_approved_at / order_delivered_carrier_date /
    order_delivered_customer_date with a placeholder 1900-01-01 instead
    of true nulls. This script coerces those columns with
    pd.to_datetime(errors='coerce') so missing values become real NaT
    (SQL NULL on export), not a fake date that would corrupt any
    delivery-time or on-time-rate measure.
"""

import pandas as pd
import os

# ==========================================
# 0. SETUP DYNAMIC FILE PATHS (pattern reused from Portfolio #2)
# ==========================================
script_dir = os.path.dirname(os.path.abspath(__file__))
RAW_PATH = os.path.join(script_dir, '..', 'raw_data', 'olist_orders_dataset.csv')
OUT_PATH = os.path.join(script_dir, '..', 'cleaned_data', 'orders_delivery_clean.csv')

DATE_COLS = [
    "order_purchase_timestamp",
    "order_approved_at",
    "order_delivered_carrier_date",
    "order_delivered_customer_date",
    "order_estimated_delivery_date",
]

KEEP_COLS = [
    "order_id",
    "order_status",
] + DATE_COLS


def load_raw(path):
    df = pd.read_csv(path)
    expected_rows = 99441
    if len(df) != expected_rows:
        print(f"WARNING: expected {expected_rows} rows, got {len(df)}. "
              f"Source file may have changed — re-verify before trusting output.")
    return df


def coerce_dates(df):
    for col in DATE_COLS:
        before_nulls = df[col].isna().sum()
        df[col] = pd.to_datetime(df[col], errors="coerce")
        after_nulls = df[col].isna().sum()
        newly_failed = after_nulls - before_nulls
        if newly_failed > 0:
            print(f"WARNING: {newly_failed} values in {col} failed to parse "
                  f"as dates and were coerced to NaT. Investigate before loading.")

        # Guard against the known Portfolio #1/#2 placeholder-date bug —
        # if this ever shows up again, it means a placeholder crept in
        # somewhere upstream and needs investigating before trusting output.
        placeholder_count = (df[col] == "1900-01-01").sum()
        if placeholder_count > 0:
            print(f"WARNING: {placeholder_count} placeholder 1900-01-01 "
                  f"values found in {col} — investigate before trusting output.")

    return df


def build_output(df):
    out = df[KEEP_COLS].copy()

    null_delivered = out["order_delivered_customer_date"].isna().sum()
    print(f"Orders never delivered (null order_delivered_customer_date): "
          f"{null_delivered} / {len(out)} ({null_delivered / len(out):.1%})")

    return out


def validate(out, raw_row_count):
    print("--- Validation ---")
    print(f"Raw rows: {raw_row_count}")
    print(f"Output rows: {len(out)}")

    assert out["order_id"].is_unique, "orders_delivery_clean must be one row per order_id"
    assert len(out) == raw_row_count, "row count changed unexpectedly during cleaning"

    print("All checks passed.")


def main():
    df = load_raw(RAW_PATH)
    raw_row_count = len(df)

    df = coerce_dates(df)
    out = build_output(df)

    validate(out, raw_row_count)

    out.to_csv(OUT_PATH, index=False)
    print(f"\nWrote {OUT_PATH}")


if __name__ == "__main__":
    main()