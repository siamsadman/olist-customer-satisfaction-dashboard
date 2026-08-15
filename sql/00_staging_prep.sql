/* ============================================================================
   Portfolio #3 — Customer Experience & Satisfaction
   00_staging_prep.sql   |   Staging tables for Navicat CSV import
   Database: Olist_Retail   |   Schema: dbo   |   SQL Server (Docker)

   PURPOSE
     Creates the three staging tables that receive the cleaned CSVs produced by
     the Python pipeline, then verifies the import landed correctly before any
     dimensional modelling work begins.

   PIPELINE POSITION
     Raw Kaggle CSVs
        -> scripts/data_cleaning.py   -> cleaned_data/fact_reviews_clean.csv
                                      -> cleaned_data/bridge_review_order_clean.csv
        -> scripts/clean_orders.py    -> cleaned_data/orders_delivery_clean.csv
        -> Navicat CSV import         -> THIS FILE's tables
        -> 01_schema.sql              -> fact + bridge table DDL
        -> 02_load_facts.sql          -> populate facts and bridges
        -> 03_validation.sql          -> data quality checks

   RUN THIS FILE FIRST, then import the CSVs, then run section 4.

   EXPECTED ROW COUNTS AFTER IMPORT
       stg_reviews                98,410
       stg_review_order_bridge    99,224
       stg_orders_delivery        99,441

   SOURCE CSV -> TABLE MAPPING
       fact_reviews_clean.csv          -> stg_reviews
       bridge_review_order_clean.csv   -> stg_review_order_bridge
       orders_delivery_clean.csv       -> stg_orders_delivery

   Portfolio #3 is self-contained. It READS Portfolio #1/#2 objects
   (fact_order_items, bridge_order_seller, bridge_order_product, dim_date,
   dim_customer, dim_product, dim_seller) but never modifies them, so nothing
   already published is put at risk by re-running this pipeline.
   ============================================================================ */

USE Olist_Retail;
GO


/* ----------------------------------------------------------------------------
   0. DROP EXISTING STAGING TABLES
      Staging is disposable by design -- no constraints, no dependants.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.stg_reviews', 'U')             IS NOT NULL DROP TABLE dbo.stg_reviews;
IF OBJECT_ID('dbo.stg_review_order_bridge', 'U') IS NOT NULL DROP TABLE dbo.stg_review_order_bridge;
IF OBJECT_ID('dbo.stg_orders_delivery', 'U')     IS NOT NULL DROP TABLE dbo.stg_orders_delivery;
GO


/* ----------------------------------------------------------------------------
   1. stg_reviews                                          Expect 98,410 rows
      Source: cleaned_data/fact_reviews_clean.csv
      Origin: olist_order_reviews_dataset.csv

      TEXT COLUMN SIZING -- deliberate, not incidental.
      These columns were originally declared NVARCHAR(MAX). Navicat's import
      collapsed to roughly 10 rows/sec, taking over 10 minutes for 98K rows,
      because MAX-typed columns are stored off-row and defeat bulk insert
      optimisation. Bounding them to NVARCHAR(4000) brought the same import
      down to 41 seconds. Longest observed message is well inside 4000 chars.

      has_comment is a BIT computed in Python as (title present OR message
      present). review_comment_title is 88.3% blank in the source and carries
      almost no independent signal, so it is retained for reference only --
      every measure uses the flag.

      NOTE FOR THE PYTHON SIDE: pandas writes booleans as True/False, which
      SQL Server's BIT type will not accept on import. data_cleaning.py applies
      .astype(int) before to_csv() so the column arrives as 1/0.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.stg_reviews (
    review_id               VARCHAR(32)     NOT NULL,
    review_score            TINYINT         NOT NULL,   -- 1..5
    has_comment             BIT             NOT NULL,   -- 1/0, not True/False
    review_comment_title    NVARCHAR(200)   NULL,       -- 88.3% blank
    review_comment_message  NVARCHAR(4000)  NULL,       -- NOT NVARCHAR(MAX)
    review_creation_date    DATETIME        NULL,
    review_answer_timestamp DATETIME        NULL
);
GO


/* ----------------------------------------------------------------------------
   2. stg_review_order_bridge                              Expect 99,224 rows
      Source: cleaned_data/bridge_review_order_clean.csv

      Exists because reviews and orders are genuinely many-to-many in the Olist
      data, which is not obvious from the source file layout:
        - 789 review_ids appear against more than one order. These rows are
          identical on every field except order_id.
        - 547 orders carry more than one review (maximum 3).
      Flattening this to a single order_id column on the review table would
      either duplicate reviews or silently drop order associations. The count
      here (99,224) legitimately exceeds the review count (98,410) as a result.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.stg_review_order_bridge (
    review_id  VARCHAR(32)  NOT NULL,
    order_id   VARCHAR(32)  NOT NULL
);
GO


/* ----------------------------------------------------------------------------
   3. stg_orders_delivery                                  Expect 99,441 rows
      Source: cleaned_data/orders_delivery_clean.csv
      Origin: olist_orders_dataset.csv

      CRITICAL -- NULL HANDLING ON THE DATETIME COLUMNS.
      Portfolio #1's original data_cleaning.py filled missing values in
      order_approved_at, order_delivered_carrier_date and
      order_delivered_customer_date with a placeholder 1900-01-01 00:00:00
      rather than true NULLs. Portfolio #3 does date arithmetic on these
      columns (delivery-to-review timing, lateness, delay days), so a
      placeholder date would silently produce nonsense intervals of roughly
      43,000 days instead of a NULL that propagates honestly.

      clean_orders.py uses pd.to_datetime(errors='coerce') so genuinely
      missing timestamps arrive as NULL. Section 4 verifies this explicitly --
      do not skip that check on a fresh rebuild.

      All five columns are nullable on purpose. An order that never reached the
      customer has no delivery timestamp, and that absence is information: it
      drives the "Not Delivered" bucket and the three-valued is_late logic
      downstream.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.stg_orders_delivery (
    order_id                       VARCHAR(32)  NOT NULL,
    order_status                   VARCHAR(20)  NOT NULL,
    order_purchase_timestamp       DATETIME     NULL,
    order_approved_at              DATETIME     NULL,
    order_delivered_carrier_date   DATETIME     NULL,
    order_delivered_customer_date  DATETIME     NULL,
    order_estimated_delivery_date  DATETIME     NULL
);
GO


/* ============================================================================
   >>> IMPORT THE THREE CSVs VIA NAVICAT NOW, THEN RUN SECTION 4 <<<

   NAVICAT IMPORT SETTINGS -- the date format setting is not optional.
   Navicat's CSV wizard will silently mis-parse datetime columns as TIME type
   if the date format is left at its default. The import reports success and
   the error only surfaces later as impossible date arithmetic.

       Date order:      YMD
       Date delimiter:  -  (hyphen)
       Time delimiter:  :  (colon)
       Encoding:        UTF-8
       Field delimiter: ,  (comma)
       Text qualifier:  "  (double quote)

   Section 4 checks this. Run it every time, including on rebuilds.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   4. POST-IMPORT VERIFICATION
   ---------------------------------------------------------------------------- */

/* -- CHECK 1: row counts. Expect 98,410 / 99,224 / 99,441 -------------------- */
SELECT 'stg_reviews'             AS table_name, COUNT(*) AS actual, 98410 AS expected FROM dbo.stg_reviews
UNION ALL SELECT 'stg_review_order_bridge', COUNT(*), 99224 FROM dbo.stg_review_order_bridge
UNION ALL SELECT 'stg_orders_delivery',     COUNT(*), 99441 FROM dbo.stg_orders_delivery;

/* -- CHECK 2: datetime columns really are DATETIME, not TIME -----------------
   This is the Navicat mis-parse check. Every row must report 'datetime'.
   If any row shows 'time', the import used the wrong date format: truncate the
   table, correct the wizard settings above, and re-import. */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('stg_reviews', 'stg_orders_delivery')
  AND (COLUMN_NAME LIKE '%date%' OR COLUMN_NAME LIKE '%timestamp%')
ORDER BY TABLE_NAME, COLUMN_NAME;

/* -- CHECK 3: no 1900-01-01 placeholder dates survived -----------------------
   Every count must be 0. A non-zero result means the placeholder-fill bug from
   Portfolio #1's cleaning script has resurfaced; fix the Python side and
   re-import rather than patching the values here. */
SELECT 'order_approved_at' AS column_checked,
       SUM(CASE WHEN order_approved_at = '1900-01-01' THEN 1 ELSE 0 END) AS placeholder_rows,
       SUM(CASE WHEN order_approved_at IS NULL        THEN 1 ELSE 0 END) AS null_rows
FROM dbo.stg_orders_delivery
UNION ALL
SELECT 'order_delivered_carrier_date',
       SUM(CASE WHEN order_delivered_carrier_date = '1900-01-01' THEN 1 ELSE 0 END),
       SUM(CASE WHEN order_delivered_carrier_date IS NULL        THEN 1 ELSE 0 END)
FROM dbo.stg_orders_delivery
UNION ALL
SELECT 'order_delivered_customer_date',
       SUM(CASE WHEN order_delivered_customer_date = '1900-01-01' THEN 1 ELSE 0 END),
       SUM(CASE WHEN order_delivered_customer_date IS NULL        THEN 1 ELSE 0 END)
FROM dbo.stg_orders_delivery;

/* -- CHECK 4: review dates fall inside dim_date's existing range -------------
   dim_date was built in Portfolio #1 and extended in #2; it currently spans
   2016-09-04 to 2018-11-12 (800 rows, no gaps). Portfolio #3 introduces no
   date column that projects past that range, so NO extension is required --
   but verify before loading rather than discovering it as a foreign key error.
   Expect both out_of_range counts to be 0. */
SELECT MIN(review_creation_date)    AS min_creation,
       MAX(review_creation_date)    AS max_creation,
       MIN(review_answer_timestamp) AS min_answer,
       MAX(review_answer_timestamp) AS max_answer,
       SUM(CASE WHEN CAST(review_creation_date AS DATE)
                     NOT BETWEEN (SELECT MIN(full_date) FROM dbo.dim_date)
                             AND (SELECT MAX(full_date) FROM dbo.dim_date)
                THEN 1 ELSE 0 END)  AS creation_out_of_range,
       SUM(CASE WHEN CAST(review_answer_timestamp AS DATE)
                     NOT BETWEEN (SELECT MIN(full_date) FROM dbo.dim_date)
                             AND (SELECT MAX(full_date) FROM dbo.dim_date)
                THEN 1 ELSE 0 END)  AS answer_out_of_range
FROM dbo.stg_reviews;

/* -- CHECK 5: key integrity. Expect 0 duplicates and 0 orphans --------------- */
SELECT (SELECT COUNT(*) FROM (SELECT review_id FROM dbo.stg_reviews
                              GROUP BY review_id HAVING COUNT(*) > 1) d)  AS duplicate_review_ids,
       (SELECT COUNT(*) FROM (SELECT order_id FROM dbo.stg_orders_delivery
                              GROUP BY order_id HAVING COUNT(*) > 1) d)   AS duplicate_order_ids,
       (SELECT COUNT(*) FROM dbo.stg_review_order_bridge b
         WHERE NOT EXISTS (SELECT 1 FROM dbo.stg_reviews r
                            WHERE r.review_id = b.review_id))             AS orphan_reviews,
       (SELECT COUNT(*) FROM dbo.stg_review_order_bridge b
         WHERE NOT EXISTS (SELECT 1 FROM dbo.stg_orders_delivery o
                            WHERE o.order_id = b.order_id))               AS orphan_orders;

/* -- CHECK 6: has_comment imported as 1/0, and review_score is in range ------
   Expect only values 0 and 1 for the flag, and 1 through 5 for the score. */
SELECT has_comment, COUNT(*) AS rows_with_value
FROM dbo.stg_reviews GROUP BY has_comment ORDER BY has_comment;

SELECT review_score, COUNT(*) AS rows_with_value
FROM dbo.stg_reviews GROUP BY review_score ORDER BY review_score;
GO
