/* ============================================================================
   Portfolio #3 — Customer Experience & Satisfaction
   02_load_facts.sql   |   Populate fact + bridge tables
   Database: Olist_Retail   |   Schema: dbo   |   SQL Server (Docker)

   PREREQUISITES
       00_staging_prep.sql   -> stg_reviews, stg_review_order_bridge,
                                stg_orders_delivery loaded from cleaned CSVs
       01_schema.sql         -> empty fact + bridge tables created

   SOURCES
     Portfolio #3 staging (this portfolio):
         stg_reviews               98,410
         stg_review_order_bridge   99,224
         stg_orders_delivery       99,441
     Portfolio #1 / #2 objects — READ ONLY, never modified:
         fact_order_items         112,650   (order_value, customer_unique_id)
         bridge_order_seller      100,010   (seller attribution)
         bridge_order_product     102,425   (product attribution)
         dim_product               32,951   (category_name_en)
         dim_customer              96,096
         dim_date                     800

   EXPECTED ROW COUNTS AFTER THIS SCRIPT
         fact_reviews                    98,410
         bridge_review_order             99,224
         bridge_review_seller            99,549
         bridge_review_product          102,172
         bridge_review_category_delay   103,831

   Each section ends with a verification block. Run them. Every measure in the
   dashboard was validated against an independent SQL query before being
   trusted in a visual, and this file follows the same rule.
   ============================================================================ */

USE Olist_Retail;
GO

-- Truncate children before parents (FK order).
TRUNCATE TABLE dbo.bridge_review_category_delay;
DELETE FROM dbo.bridge_review_product;
DELETE FROM dbo.bridge_review_seller;
DELETE FROM dbo.bridge_review_order;
DELETE FROM dbo.fact_reviews;
GO


/* ============================================================================
   1. fact_reviews          Grain: one row per review_id.       Expect 98,410
   ============================================================================
   Date keys are built arithmetically (y*10000 + m*100 + d) rather than with
   FORMAT(), which is roughly an order of magnitude slower over ~100K rows and
   is culture-dependent.

   response_days = whole days from review creation to seller response.
   Verified after load: 0 nulls, 0 negatives, range 0-518. No filtering guard
   is needed on this column, unlike delivery_to_review_days in section 2.
   ============================================================================ */

INSERT INTO dbo.fact_reviews (
    review_id, review_score, has_comment,
    review_comment_title, review_comment_message,
    creation_date_key, answer_date_key, response_days
)
SELECT
    r.review_id,
    r.review_score,
    r.has_comment,
    r.review_comment_title,
    r.review_comment_message,
    YEAR(r.review_creation_date)    * 10000
        + MONTH(r.review_creation_date) * 100
        + DAY(r.review_creation_date)              AS creation_date_key,
    YEAR(r.review_answer_timestamp) * 10000
        + MONTH(r.review_answer_timestamp) * 100
        + DAY(r.review_answer_timestamp)           AS answer_date_key,
    DATEDIFF(DAY, r.review_creation_date, r.review_answer_timestamp) AS response_days
FROM dbo.stg_reviews AS r;
GO

/* -- VERIFY 1: expect 98,410 / avg 4.09 / 43.07% commented -------------------- */
SELECT COUNT(*)                                            AS rows_loaded,
       CAST(AVG(review_score * 1.0) AS DECIMAL(4,2))       AS avg_score,
       CAST(100.0 * SUM(CAST(has_comment AS INT))
            / COUNT(*) AS DECIMAL(5,2))                    AS pct_with_comment
FROM dbo.fact_reviews;

/* -- VERIFY 2: response_days integrity. Expect 0 / 0 / 0 / 518 / 2.583 -------- */
SELECT SUM(CASE WHEN response_days IS NULL THEN 1 ELSE 0 END) AS null_rows,
       SUM(CASE WHEN response_days < 0     THEN 1 ELSE 0 END) AS negative_rows,
       MIN(response_days)                                     AS min_days,
       MAX(response_days)                                     AS max_days,
       CAST(AVG(response_days * 1.0) AS DECIMAL(6,3))         AS avg_days
FROM dbo.fact_reviews;

/* -- VERIFY 3: no orphan date keys. Expect 0 rows ----------------------------- */
SELECT COUNT(*) AS orphan_date_keys
FROM dbo.fact_reviews f
WHERE (f.creation_date_key IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.dim_date d WHERE d.date_key = f.creation_date_key))
   OR (f.answer_date_key   IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.dim_date d WHERE d.date_key = f.answer_date_key));
GO


/* ============================================================================
   2. bridge_review_order   Grain: review_id x order_id.        Expect 99,224
   ============================================================================
   Resolves the genuine many-to-many between reviews and orders: 789 review_ids
   appear on more than one order, and 547 orders carry more than one review
   (max 3). Order-level attributes are denormalised onto the bridge so the
   Drivers page can slice by delivery outcome and order value in one hop.

   is_late is deliberately three-valued:
       NULL  = never delivered, lateness undefined  (2,865 rows)
       0     = delivered on or before the estimate
       1     = delivered after the estimate
   This distinction is load-bearing. In DAX, BLANK() = FALSE evaluates to TRUE,
   so a naive [is_late] = FALSE test silently pulled the never-delivered rows
   into the on-time bucket and shifted the on-time average from 4.29 to 4.22.
   Coercing NULL to 0 here would bake that error into the data itself.

   delay_days is signed: positive = late, negative = delivered early.

   delivery_to_review_days: 5,127 rows come out NEGATIVE (review created before
   the recorded delivery timestamp). Investigated and ruled out as a batch
   artifact -- only 56% fall within -7 days. Retained raw and excluded at
   measure level via a >= 0 filter, so the anomaly stays visible rather than
   being silently deleted here.

   order_value and customer_unique_id are aggregated from Portfolio #1's
   fact_order_items (item grain, 112,650 rows) up to order grain. The LEFT JOIN
   is intentional: ~775 orders were cancelled or went unavailable before
   fulfilment and have zero item rows, which yields 759 NULL order_values here.
   Those are bucketed as "Unknown" in the model, never coerced to zero.
   ============================================================================ */

INSERT INTO dbo.bridge_review_order (
    review_id, order_id, order_status,
    delivered_date_key, estimated_delivery_date_key,
    is_delivered, is_late, delay_days,
    customer_unique_id, delivery_to_review_days, order_value
)
SELECT
    b.review_id,
    b.order_id,
    o.order_status,

    CASE WHEN o.order_delivered_customer_date IS NOT NULL
         THEN YEAR(o.order_delivered_customer_date)    * 10000
            + MONTH(o.order_delivered_customer_date)   * 100
            + DAY(o.order_delivered_customer_date)
    END                                                     AS delivered_date_key,

    CASE WHEN o.order_estimated_delivery_date IS NOT NULL
         THEN YEAR(o.order_estimated_delivery_date)    * 10000
            + MONTH(o.order_estimated_delivery_date)   * 100
            + DAY(o.order_estimated_delivery_date)
    END                                                     AS estimated_delivery_date_key,

    CASE WHEN o.order_delivered_customer_date IS NOT NULL
         THEN 1 ELSE 0 END                                  AS is_delivered,

    -- NULL when never delivered. Do NOT collapse to 0.
    CASE WHEN o.order_delivered_customer_date IS NULL THEN NULL
         WHEN CAST(o.order_delivered_customer_date AS DATE)
              > CAST(o.order_estimated_delivery_date AS DATE) THEN 1
         ELSE 0 END                                         AS is_late,

    DATEDIFF(DAY, CAST(o.order_estimated_delivery_date AS DATE),
                  CAST(o.order_delivered_customer_date AS DATE))  AS delay_days,

    oi.customer_unique_id,

    DATEDIFF(DAY, CAST(o.order_delivered_customer_date AS DATE),
                  CAST(r.review_creation_date AS DATE))           AS delivery_to_review_days,

    oi.order_value
FROM dbo.stg_review_order_bridge AS b
INNER JOIN dbo.stg_orders_delivery AS o
        ON o.order_id = b.order_id
INNER JOIN dbo.stg_reviews AS r
        ON r.review_id = b.review_id
LEFT JOIN (
        SELECT order_id,
               MIN(customer_unique_id) AS customer_unique_id,
               SUM(price)              AS order_value
        FROM dbo.fact_order_items
        GROUP BY order_id
) AS oi ON oi.order_id = b.order_id;
GO

/* -- VERIFY 4: expect 99,224 rows / 2,865 undelivered / 759 null values ------- */
SELECT COUNT(*)                                                  AS rows_loaded,
       SUM(CASE WHEN is_late IS NULL     THEN 1 ELSE 0 END)      AS never_delivered,
       SUM(CASE WHEN is_late = 1         THEN 1 ELSE 0 END)      AS late_rows,
       SUM(CASE WHEN is_late = 0         THEN 1 ELSE 0 END)      AS on_time_rows,
       SUM(CASE WHEN order_value IS NULL THEN 1 ELSE 0 END)      AS null_order_value,
       SUM(CASE WHEN delivery_to_review_days < 0 THEN 1 ELSE 0 END) AS negative_timing
FROM dbo.bridge_review_order;

/* -- VERIFY 5: the headline Drivers finding. Expect 4.29 / 2.57 / gap 1.73 ----
   The NOT NULL guard on the on-time branch mirrors the NOT ISBLANK() guard the
   equivalent DAX measure carries. Without it this returns 4.22, not 4.29. */
SELECT CAST(AVG(CASE WHEN b.is_late = 0 AND b.is_late IS NOT NULL
                     THEN f.review_score * 1.0 END) AS DECIMAL(4,2)) AS avg_score_on_time,
       CAST(AVG(CASE WHEN b.is_late = 1
                     THEN f.review_score * 1.0 END) AS DECIMAL(4,2)) AS avg_score_late
FROM dbo.bridge_review_order b
JOIN dbo.fact_reviews f ON f.review_id = b.review_id;

/* -- VERIFY 6: order_value definition check ----------------------------------
   Confirms whether order_value is price-only or price + freight. The price-only
   column should reproduce the Order Value bucket boundaries used on the Drivers
   page. If the freight-inclusive figure matches your live data instead, change
   SUM(price) to SUM(price + freight_value) in the load above and re-run. */
SELECT TOP 5 order_id,
       CAST(SUM(price) AS DECIMAL(10,2))                  AS price_only,
       CAST(SUM(price + freight_value) AS DECIMAL(10,2))  AS price_plus_freight
FROM dbo.fact_order_items
GROUP BY order_id
ORDER BY order_id;
GO


/* ============================================================================
   3. bridge_review_seller  Grain: review_id x seller_id.       Expect 99,549
   ============================================================================
   Built through Portfolio #2's bridge_order_seller (100,010 rows) rather than
   fact_order_items directly -- the order/seller pairing is already resolved
   there, so this avoids re-deriving it and keeps the two portfolios consistent.

   99,549 rows against 98,410 reviews: multi-seller orders attach one review to
   several sellers. Per-seller aggregates are correct, but seller-level review
   counts do NOT sum to 98,410 across all sellers, so any "share of total
   reviews" measure at seller grain overstates slightly. Documented in the
   README rather than silently corrected.
   ============================================================================ */

INSERT INTO dbo.bridge_review_seller (review_id, seller_id)
SELECT DISTINCT b.review_id, s.seller_id
FROM dbo.stg_review_order_bridge AS b
INNER JOIN dbo.bridge_order_seller AS s
        ON s.order_id = b.order_id
WHERE s.seller_id IS NOT NULL;
GO

/* -- VERIFY 7: expect 99,549 rows / 3,090 sellers / 0 orphans ----------------- */
SELECT COUNT(*)                        AS rows_loaded,
       COUNT(DISTINCT seller_id)       AS distinct_sellers,
       COUNT(DISTINCT review_id)       AS distinct_reviews
FROM dbo.bridge_review_seller;

SELECT COUNT(*) AS orphan_sellers
FROM dbo.bridge_review_seller b
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_seller d WHERE d.seller_id = b.seller_id);
GO


/* ============================================================================
   4. bridge_review_product Grain: review_id x product_id.      Expect 102,172
   ============================================================================ */

INSERT INTO dbo.bridge_review_product (review_id, product_id)
SELECT DISTINCT b.review_id, p.product_id
FROM dbo.stg_review_order_bridge AS b
INNER JOIN dbo.bridge_order_product AS p
        ON p.order_id = b.order_id
WHERE p.product_id IS NOT NULL;
GO

/* -- VERIFY 8: expect 102,172 rows / 0 orphans -------------------------------- */
SELECT COUNT(*)                    AS rows_loaded,
       COUNT(DISTINCT product_id)  AS distinct_products
FROM dbo.bridge_review_product;

SELECT COUNT(*) AS orphan_products
FROM dbo.bridge_review_product b
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_product d WHERE d.product_id = b.product_id);
GO


/* ============================================================================
   5. bridge_review_category_delay                              Expect 103,831
   ============================================================================
   DELIBERATE DENORMALISATION -- see 01_schema.sql for the full rationale.

   The category-by-delivery-outcome heatmap has to cross two independent
   many-to-many bridges in one filter context: category (review -> product ->
   dim_product) and delay bucket (review -> order). Three separate DAX
   approaches each returned wrong-but-plausible numbers, the standard failure
   mode for averaging across two unrelated m2m paths. Pre-flattening the join
   in SQL makes the result deterministic and reproducible against these
   validation queries.

   This table stays DISCONNECTED in the Power BI model. It has no foreign keys
   and must not be given relationships.

   The delay buckets below must stay in sync with the [Delay Bucket] calculated
   column on bridge_review_order -- same boundaries, same labels, same
   never-delivered-first ordering.

   Row count exceeds fact_reviews because a review spanning several products in
   different categories yields one row per (review, category, bucket) triple.
   ============================================================================ */

INSERT INTO dbo.bridge_review_category_delay
    (review_id, category_name_en, delay_bucket, review_score)
SELECT DISTINCT
    f.review_id,
    ISNULL(dp.category_name_en, 'Unknown')  AS category_name_en,
    CASE WHEN bo.is_late IS NULL      THEN 'Not Delivered'
         WHEN bo.is_late = 0          THEN 'On Time'
         WHEN bo.delay_days <= 7      THEN '1-7 Days Late'
         WHEN bo.delay_days <= 14     THEN '8-14 Days Late'
         ELSE                              '15+ Days Late'
    END                                     AS delay_bucket,
    f.review_score
FROM dbo.fact_reviews AS f
INNER JOIN dbo.bridge_review_order   AS bo ON bo.review_id = f.review_id
INNER JOIN dbo.bridge_review_product AS bp ON bp.review_id = f.review_id
LEFT  JOIN dbo.dim_product           AS dp ON dp.product_id = bp.product_id;
GO

/* -- VERIFY 9: expect 103,831 rows across 5 buckets --------------------------- */
SELECT delay_bucket,
       COUNT(*)                                      AS rows_in_bucket,
       COUNT(DISTINCT category_name_en)              AS categories,
       CAST(AVG(review_score * 1.0) AS DECIMAL(4,2)) AS avg_score
FROM dbo.bridge_review_category_delay
GROUP BY delay_bucket
ORDER BY avg_score DESC;

/* -- VERIFY 10: heatmap cross-check. These figures must match the Drivers page
   matrix exactly -- that equality is the whole point of pre-flattening. */
SELECT TOP 10 category_name_en,
       COUNT(*) AS total_rows,
       CAST(AVG(CASE WHEN delay_bucket = 'On Time'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2)) AS on_time,
       CAST(AVG(CASE WHEN delay_bucket = '15+ Days Late'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2)) AS late_15_plus
FROM dbo.bridge_review_category_delay
WHERE category_name_en <> 'Unknown'
GROUP BY category_name_en
ORDER BY COUNT(*) DESC;
GO


/* ============================================================================
   6. FINAL LOAD SUMMARY
      All five counts must match exactly before the model is refreshed.
   ============================================================================ */
SELECT 'fact_reviews'                 AS table_name, COUNT(*) AS actual, 98410  AS expected FROM dbo.fact_reviews
UNION ALL SELECT 'bridge_review_order',            COUNT(*),  99224  FROM dbo.bridge_review_order
UNION ALL SELECT 'bridge_review_seller',           COUNT(*),  99549  FROM dbo.bridge_review_seller
UNION ALL SELECT 'bridge_review_product',          COUNT(*), 102172  FROM dbo.bridge_review_product
UNION ALL SELECT 'bridge_review_category_delay',   COUNT(*), 103831  FROM dbo.bridge_review_category_delay;
GO
