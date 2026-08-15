"""
Portfolio #3 — Customer Experience & Satisfaction
data_cleaning.py

Cleans olist_order_reviews_dataset.csv and produces two output files:
  1. fact_reviews staging data  -> one row per unique review_id
  2. bridge_review_order staging data -> full review_id <-> order_id pairs

Findings this script encodes (from scratch exploration, confirmed):
  - 789 review_ids appear more than once in the raw file, always with
    identical review_score / comments / dates, differing only on order_id.
    This is a genuine many-to-many between reviews and orders (max 3
    reviews per order; some reviews attached to multiple orders).
  - review_comment_title is 88.3% blank and never carries signal beyond
    review_comment_message, so both are collapsed into one has_comment flag.
  - Date columns arrive as strings and must be coerced to real datetimes.
  - dim_date already covers the full review_creation_date /
    review_answer_timestamp range (2016-09-04 to 2018-11-12) - confirmed
    against SQL, no extension needed.
"""

import pandas as pd
import os

# ==========================================
# 0. SETUP DYNAMIC FILE PATHS (pattern reused from Portfolio #2)
# ==========================================
script_dir = os.path.dirname(os.path.abspath(__file__))
RAW_PATH = os.path.join(script_dir, '..', 'raw_data', 'olist_order_reviews_dataset.csv')
FACT_OUT_PATH = os.path.join(script_dir, '..', 'cleaned_data', 'fact_reviews_clean.csv')
BRIDGE_OUT_PATH = os.path.join(script_dir, '..', 'cleaned_data', 'bridge_review_order_clean.csv')

DATE_COLS = ["review_creation_date", "review_answer_timestamp"]


def load_raw(path):
    df = pd.read_csv(path)
    expected_rows = 99224
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
    return df


def build_bridge(df):
    """One row per unique (review_id, order_id) pair — the true grain of
    the raw file. This is the many-to-many link table."""
    return df[["review_id", "order_id"]].drop_duplicates()


def build_fact(df):
    """One row per unique review_id. Duplicated review_ids were confirmed
    identical on every column except order_id, so it's safe to keep the
    first occurrence and drop order_id — that relationship lives in the
    bridge table instead."""
    fact = df.drop_duplicates(subset="review_id", keep="first").copy()

    fact["has_comment"] = (
        fact["review_comment_title"].notna() | fact["review_comment_message"].notna()
    )
    
    fact["has_comment"] = fact["has_comment"].astype(int)
    
    fact = fact.drop(columns=["order_id"])

    return fact[[
        "review_id",
        "review_score",
        "has_comment",
        "review_comment_title",
        "review_comment_message",
        "review_creation_date",
        "review_answer_timestamp",
    ]]


def validate(fact, bridge, raw_row_count):
    print("--- Validation ---")
    print(f"Raw rows: {raw_row_count}")
    print(f"fact_reviews rows (unique review_id): {len(fact)}")
    print(f"bridge_review_order rows (unique pairs): {len(bridge)}")

    assert fact["review_id"].is_unique, "fact_reviews must be one row per review_id"
    assert fact["review_score"].between(1, 5).all(), "review_score out of expected 1-5 range"
    assert bridge["review_id"].isin(fact["review_id"]).all(), \
        "bridge has review_ids not present in fact_reviews"

    print(f"has_comment rate: {fact['has_comment'].mean():.1%}")
    print("All checks passed.")


def main():
    df = load_raw(RAW_PATH)
    raw_row_count = len(df)

    df = coerce_dates(df)

    bridge = build_bridge(df)
    fact = build_fact(df)

    validate(fact, bridge, raw_row_count)

    fact.to_csv(FACT_OUT_PATH, index=False)
    bridge.to_csv(BRIDGE_OUT_PATH, index=False)

    print(f"\nWrote {FACT_OUT_PATH}")
    print(f"Wrote {BRIDGE_OUT_PATH}")


if __name__ == "__main__":
    main()