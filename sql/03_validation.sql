/* ============================================================================
   Portfolio #3 — Customer Experience & Satisfaction
   03_validation.sql   |   Data quality checks and DAX measure validation
   Database: Olist_Retail   |   Schema: dbo   |   SQL Server (Docker)

   PURPOSE
     Two jobs in one file.

     Part A documents the data quirks found in the Olist review data and the
     evidence behind each modelling decision. These are the queries that were
     run BEFORE building anything, and they are what turned assumptions into
     facts -- several of them changed the design.

     Part B validates every DAX measure in the dashboard against an independent
     SQL query. This is not a formality. Running it caught three real bugs that
     would otherwise have shipped silently: a blank-handling error inflating the
     on-time average, a wrong-table field binding flattening an entire matrix,
     and a bridge cross-filter direction that made every category look
     identical. A measure that has not been checked against SQL is a measure
     that has not been checked.

     Every figure quoted on the dashboard traces to a query in this file.

   PREREQUISITES
     00_staging_prep.sql, 01_schema.sql and 02_load_facts.sql have all run.
   ============================================================================ */

USE Olist_Retail;
GO


/* ============================================================================
   PART A — DATA QUALITY AND DESIGN EVIDENCE
   ============================================================================ */


/* ----------------------------------------------------------------------------
   A1. Reviews and orders are genuinely many-to-many
       Expect: 789 reviews on multiple orders, 547 orders with multiple reviews,
               maximum 3 reviews on a single order.

       This is the evidence for bridge_review_order. Without it the obvious
       design -- one order_id column on the review table -- looks correct and
       quietly loses data. The duplicated review rows are identical on every
       field except order_id, so a careless DISTINCT would also have hidden it.
   ---------------------------------------------------------------------------- */
SELECT 'reviews spanning >1 order' AS finding,
       COUNT(*)                    AS occurrences
FROM (SELECT review_id FROM dbo.stg_review_order_bridge
      GROUP BY review_id HAVING COUNT(DISTINCT order_id) > 1) x
UNION ALL
SELECT 'orders with >1 review',
       COUNT(*)
FROM (SELECT order_id FROM dbo.stg_review_order_bridge
      GROUP BY order_id HAVING COUNT(DISTINCT review_id) > 1) y;

SELECT reviews_per_order, COUNT(*) AS order_count
FROM (SELECT order_id, COUNT(DISTINCT review_id) AS reviews_per_order
      FROM dbo.stg_review_order_bridge GROUP BY order_id) z
GROUP BY reviews_per_order
ORDER BY reviews_per_order;
GO


/* ----------------------------------------------------------------------------
   A2. review_comment_title is 88.3% blank
       Evidence for collapsing title and message into a single has_comment flag
       rather than reporting on them separately.
   ---------------------------------------------------------------------------- */
SELECT COUNT(*)                                                       AS total_reviews,
       SUM(CASE WHEN review_comment_title   IS NULL
                  OR LTRIM(RTRIM(review_comment_title))   = ''
                THEN 1 ELSE 0 END)                                    AS blank_title,
       CAST(100.0 * SUM(CASE WHEN review_comment_title IS NULL
                               OR LTRIM(RTRIM(review_comment_title)) = ''
                             THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                               AS pct_blank_title,
       SUM(CASE WHEN review_comment_message IS NULL
                  OR LTRIM(RTRIM(review_comment_message)) = ''
                THEN 1 ELSE 0 END)                                    AS blank_message
FROM dbo.stg_reviews;
GO


/* ----------------------------------------------------------------------------
   A3. 5,127 reviews have NEGATIVE delivery-to-review timing
       Reviews created before the recorded delivery timestamp.

       Investigated as a possible batch artifact -- if the negatives clustered
       tightly just below zero, they would be a timestamp rounding issue and
       safely absorbed. They do not: only about 56% fall within -7 days, and the
       tail runs far deeper. The timing data is therefore treated as unreliable
       rather than corrected, and [Avg Days to Review] filters to >= 0.

       This excludes roughly 5.4% of reviews from that one measure only. The
       rows are retained in the table so the anomaly stays inspectable.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN delivery_to_review_days IS NULL     THEN 'NULL (not delivered)'
            WHEN delivery_to_review_days >= 0        THEN 'Valid (>= 0)'
            WHEN delivery_to_review_days >= -7       THEN 'Negative, within -7 days'
            WHEN delivery_to_review_days >= -30      THEN 'Negative, -8 to -30 days'
            ELSE                                          'Negative, beyond -30 days'
       END                                           AS timing_band,
       COUNT(*)                                      AS rows_in_band,
       CAST(100.0 * COUNT(*)
            / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_total
FROM dbo.bridge_review_order
GROUP BY CASE WHEN delivery_to_review_days IS NULL     THEN 'NULL (not delivered)'
              WHEN delivery_to_review_days >= 0        THEN 'Valid (>= 0)'
              WHEN delivery_to_review_days >= -7       THEN 'Negative, within -7 days'
              WHEN delivery_to_review_days >= -30      THEN 'Negative, -8 to -30 days'
              ELSE                                          'Negative, beyond -30 days'
         END
ORDER BY rows_in_band DESC;
GO


/* ----------------------------------------------------------------------------
   A4. 759 rows have NULL order_value
       These are the known ~775 orders that were cancelled or went unavailable
       before fulfilment and therefore have zero rows in order_items.

       Bucketed as "Unknown" and filtered out of the price chart rather than
       coerced to zero -- a cancelled order is not an order worth R$0, and
       treating it as one would drag the lowest price bucket's average down
       with reviews that have no price at all.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN order_value IS NULL THEN 'NULL (no line items)'
            ELSE 'Has value' END                     AS value_state,
       COUNT(*)                                      AS rows_affected,
       COUNT(DISTINCT order_id)                      AS distinct_orders,
       CAST(AVG(order_value) AS DECIMAL(10,2))       AS avg_order_value
FROM dbo.bridge_review_order
GROUP BY CASE WHEN order_value IS NULL THEN 'NULL (no line items)'
              ELSE 'Has value' END;

-- Confirm the NULLs really are the zero-item orders, not a join failure.
SELECT COUNT(*) AS null_value_rows_with_items
FROM dbo.bridge_review_order b
WHERE b.order_value IS NULL
  AND EXISTS (SELECT 1 FROM dbo.fact_order_items i WHERE i.order_id = b.order_id);
-- Expect 0. Anything above 0 means the aggregation in 02_load_facts.sql failed.
GO


/* ----------------------------------------------------------------------------
   A5. Oct-Dec 2016 has negligible volume
       176 / 101 / 45 reviews. Excluded from trend visuals via a visual-level
       filter of >= 2017-01-01, the same treatment Portfolios #1 and #2 gave
       the partial September 2018 extract. Three points built on 45 reviews
       would swing a monthly line chart without carrying any real signal.

       The rows stay in the model -- only the trend visuals filter them out, so
       totals and KPIs remain complete.
   ---------------------------------------------------------------------------- */
SELECT d.year,
       d.month,
       COUNT(*) AS review_count
FROM dbo.fact_reviews f
JOIN dbo.dim_date d ON d.date_key = f.creation_date_key
GROUP BY d.year, d.month
ORDER BY d.year, d.month;
GO


/* ----------------------------------------------------------------------------
   A6. Seller review-count distribution -> the >= 30 review threshold
       58.8% of sellers have fewer than 10 reviews but hold only 6.1% of review
       links, so an unfiltered "best seller" ranking would be won outright by
       one-review sellers sitting at a perfect 5.00.

       The threshold was chosen from this distribution, not guessed. The tie
       column is what settles it: 36 sellers are tied at exactly 5.00 at a
       threshold of 5, which makes any Top 10 ranking arbitrary. That collapses
       to 2 at >= 10 and 1 at >= 20.

       >= 30 was adopted: it matches the seller threshold used in Portfolio #2,
       retains 630 sellers and 83.2% of review links, and leaves exactly one
       seller at a perfect score -- a real result across 33 reviews rather than
       a tie artifact.
   ---------------------------------------------------------------------------- */
WITH seller_reviews AS (
    SELECT b.seller_id,
           COUNT(DISTINCT b.review_id) AS review_count,
           AVG(f.review_score * 1.0)   AS avg_score
    FROM dbo.bridge_review_seller b
    JOIN dbo.fact_reviews f ON f.review_id = b.review_id
    GROUP BY b.seller_id
),
thresholds AS (SELECT v FROM (VALUES (5),(10),(20),(30),(50),(75),(100)) t(v))
SELECT t.v                                                      AS min_reviews,
       COUNT(*)                                                 AS sellers_qualifying,
       CAST(100.0 * SUM(sr.review_count)
            / (SELECT SUM(review_count) FROM seller_reviews)
            AS DECIMAL(5,2))                                    AS pct_reviews_covered,
       CAST(MAX(sr.avg_score) AS DECIMAL(4,2))                  AS best_score,
       SUM(CASE WHEN sr.avg_score = 5.0 THEN 1 ELSE 0 END)      AS sellers_tied_at_5,
       CAST(MIN(sr.avg_score) AS DECIMAL(4,2))                  AS worst_score
FROM thresholds t
JOIN seller_reviews sr ON sr.review_count >= t.v
GROUP BY t.v
ORDER BY t.v;
GO


/* ----------------------------------------------------------------------------
   A7. Seller scores converge as volume rises
       The averages are flat across volume bands (4.14 / 4.12 / 4.09 / 4.10 /
       4.08), so high-volume sellers do NOT score worse -- a plausible-looking
       hypothesis this query killed before it reached a callout.

       What it does show is the RANGE collapsing: sellers with 30-49 reviews
       span 3.07 to 5.00, while the 26 largest sellers all sit between 3.49 and
       4.34. Extreme seller scores are mostly small-sample effects, which is
       both a genuine finding and independent justification for the threshold.
   ---------------------------------------------------------------------------- */
WITH seller_reviews AS (
    SELECT b.seller_id,
           COUNT(DISTINCT b.review_id) AS review_count,
           AVG(f.review_score * 1.0)   AS avg_score
    FROM dbo.bridge_review_seller b
    JOIN dbo.fact_reviews f ON f.review_id = b.review_id
    GROUP BY b.seller_id
    HAVING COUNT(DISTINCT b.review_id) >= 30
)
SELECT CASE WHEN review_count < 50  THEN '30-49'
            WHEN review_count < 100 THEN '50-99'
            WHEN review_count < 200 THEN '100-199'
            WHEN review_count < 500 THEN '200-499'
            ELSE                         '500+' END AS volume_band,
       COUNT(*)                                     AS sellers,
       SUM(review_count)                            AS reviews,
       CAST(AVG(avg_score) AS DECIMAL(4,2))         AS avg_of_seller_avgs,
       CAST(MIN(avg_score) AS DECIMAL(4,2))         AS worst,
       CAST(MAX(avg_score) AS DECIMAL(4,2))         AS best,
       CAST(MAX(avg_score) - MIN(avg_score) AS DECIMAL(4,2)) AS score_range
FROM seller_reviews
GROUP BY CASE WHEN review_count < 50  THEN '30-49'
              WHEN review_count < 100 THEN '50-99'
              WHEN review_count < 200 THEN '100-199'
              WHEN review_count < 500 THEN '200-499'
              ELSE                         '500+' END
ORDER BY MIN(review_count);
GO


/* ----------------------------------------------------------------------------
   A8. Multi-seller attribution and unattributed reviews
       bridge_review_seller holds 99,549 rows against 98,410 reviews because a
       multi-seller order attaches one review to several sellers.

       Two consequences, both documented rather than silently corrected:
         - Seller-level review counts do NOT sum to the review total, so any
           "share of all reviews" measure at seller grain overstates slightly.
         - Only 97,709 distinct reviews appear here at all. The missing 701
           belong to the zero-item orders from A4 and have no seller to
           attribute to.
   ---------------------------------------------------------------------------- */
SELECT (SELECT COUNT(*) FROM dbo.fact_reviews)                         AS total_reviews,
       (SELECT COUNT(*) FROM dbo.bridge_review_seller)                 AS bridge_rows,
       (SELECT COUNT(DISTINCT review_id) FROM dbo.bridge_review_seller) AS reviews_attributed,
       (SELECT COUNT(*) FROM dbo.fact_reviews f
         WHERE NOT EXISTS (SELECT 1 FROM dbo.bridge_review_seller b
                            WHERE b.review_id = f.review_id))          AS reviews_unattributed;
GO


/* ----------------------------------------------------------------------------
   A9. Category "Unknown" is excluded from category rankings
       n = 1,457. Not a real business category -- it is the residue of products
       whose Portuguese category names had no English translation. Left in a
       ranking it would compete with genuine categories on the strength of an
       accident of the source data.

       Note also that the source data contains a genuine typo category,
       costruction_tools_garden (sic), which is distinct from garden_tools.
       It is retained as-is: silently merging it would misstate the source.
   ---------------------------------------------------------------------------- */
SELECT ISNULL(dp.category_name_en, 'Unknown')        AS category_name_en,
       COUNT(DISTINCT bp.review_id)                  AS review_count,
       CAST(AVG(f.review_score * 1.0) AS DECIMAL(4,2)) AS avg_score
FROM dbo.bridge_review_product bp
JOIN dbo.fact_reviews f  ON f.review_id  = bp.review_id
LEFT JOIN dbo.dim_product dp ON dp.product_id = bp.product_id
WHERE dp.category_name_en IS NULL
   OR dp.category_name_en IN ('Unknown', 'costruction_tools_garden', 'garden_tools')
GROUP BY ISNULL(dp.category_name_en, 'Unknown')
ORDER BY review_count DESC;
GO


/* ============================================================================
   PART B — DAX MEASURE VALIDATION

   Every measure below was checked against these queries before being trusted
   in a visual. Expected values are stated inline.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   B1. PAGE 1 — Overview KPIs
       [Avg Review Score]        4.09
       [Total Reviews]           98,410
       [Pct 5 Star]              57.83%   (Promoters)
       [Pct 1to2 Star]           14.63%   (Detractors)
       [Pct Passive]             27.54%
       [Comment Rate]            43.07%   (Reviews With Comment)

       The three segment percentages must sum to exactly 100%. They partition
       the score range with no overlap and no gap, so a rounding drift here
       would mean one of the three filter conditions is wrong.
   ---------------------------------------------------------------------------- */
SELECT COUNT(*)                                                         AS total_reviews,
       CAST(AVG(review_score * 1.0) AS DECIMAL(4,2))                    AS avg_review_score,
       CAST(100.0 * SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                 AS pct_promoters,
       CAST(100.0 * SUM(CASE WHEN review_score BETWEEN 3 AND 4 THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                 AS pct_passive,
       CAST(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                 AS pct_detractors,
       CAST(100.0 * SUM(CAST(has_comment AS INT))
            / COUNT(*) AS DECIMAL(5,2))                                 AS pct_with_comment
FROM dbo.fact_reviews;
GO


/* ----------------------------------------------------------------------------
   B2. PAGE 1 — Review score distribution
       Expect 11,282 / 3,114 / 8,097 / 19,007 / 56,910.
   ---------------------------------------------------------------------------- */
SELECT review_score, COUNT(*) AS review_count
FROM dbo.fact_reviews
GROUP BY review_score
ORDER BY review_score;
GO


/* ----------------------------------------------------------------------------
   B3. PAGE 1 — Score by state
       Expect lowest 3.61 (Roraima), highest 4.19 (Amapa), national 4.09.

       Both extremes sit on small samples, which is exactly why the Shape Map
       carries a manual legend naming them: a viewer reading only the colour
       gradient would take them for meaningful regional performance.
   ---------------------------------------------------------------------------- */
SELECT c.customer_state,
       COUNT(*)                                        AS review_count,
       CAST(AVG(f.review_score * 1.0) AS DECIMAL(4,2)) AS avg_score
FROM dbo.bridge_review_order b
JOIN dbo.fact_reviews  f ON f.review_id          = b.review_id
JOIN dbo.dim_customer  c ON c.customer_unique_id = b.customer_unique_id
GROUP BY c.customer_state
ORDER BY avg_score;
GO


/* ----------------------------------------------------------------------------
   B4. PAGE 2 — Delivery outcome (THE BLANK-HANDLING BUG)
       Expect On Time 4.29 / 1-7 Late 3.06 / Not Delivered 1.76 /
              15+ Late 1.72 / 8-14 Late 1.68, and a 1.73 gap.

       This is the check that caught the most damaging bug in the build.
       In DAX, BLANK() = FALSE evaluates to TRUE, so the natural measure

           CALCULATE([Avg Review Score], bridge_review_order[is_late] = FALSE)

       silently swept in 2,865 never-delivered rows, pushing the on-time count
       from 88,658 to 91,523 and the on-time average from 4.29 down to 4.22.
       The fix is an explicit NOT ISBLANK() guard; the SQL equivalent is the
       IS NOT NULL condition below.

       Note the ordering: orders delayed 8-14 days score WORSE (1.68) than
       orders never delivered at all (1.76). A long wait frustrates customers
       more than an early cancellation.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN b.is_late IS NULL  THEN 'Not Delivered'
            WHEN b.is_late = 0      THEN 'On Time'
            WHEN b.delay_days <= 7  THEN '1-7 Days Late'
            WHEN b.delay_days <= 14 THEN '8-14 Days Late'
            ELSE                         '15+ Days Late'
       END                                             AS delivery_outcome,
       COUNT(*)                                        AS review_count,
       CAST(AVG(f.review_score * 1.0) AS DECIMAL(4,2)) AS avg_score
FROM dbo.bridge_review_order b
JOIN dbo.fact_reviews f ON f.review_id = b.review_id
GROUP BY CASE WHEN b.is_late IS NULL  THEN 'Not Delivered'
              WHEN b.is_late = 0      THEN 'On Time'
              WHEN b.delay_days <= 7  THEN '1-7 Days Late'
              WHEN b.delay_days <= 14 THEN '8-14 Days Late'
              ELSE                         '15+ Days Late'
         END
ORDER BY avg_score DESC;

-- Demonstrates the bug directly: correct guard vs missing guard.
SELECT CAST(AVG(CASE WHEN b.is_late = 0 AND b.is_late IS NOT NULL
                     THEN f.review_score * 1.0 END) AS DECIMAL(4,2)) AS correct_4_29,
       CAST(AVG(CASE WHEN ISNULL(b.is_late, 0) = 0
                     THEN f.review_score * 1.0 END) AS DECIMAL(4,2)) AS buggy_4_22,
       SUM(CASE WHEN b.is_late = 0 AND b.is_late IS NOT NULL THEN 1 ELSE 0 END) AS correct_88658,
       SUM(CASE WHEN ISNULL(b.is_late, 0) = 0                THEN 1 ELSE 0 END) AS buggy_91523
FROM dbo.bridge_review_order b
JOIN dbo.fact_reviews f ON f.review_id = b.review_id;
GO


/* ----------------------------------------------------------------------------
   B5. PAGE 2 — Score by order value
       Expect 4.16 / 4.16 / 4.11 / 4.08 / 3.97 / 3.93 across the six bands,
       with "Unknown" (NULL order_value) excluded from the chart.

       Higher-value orders score consistently lower, from 4.17 under R$25 down
       to 3.94 above R$500. order_value is line-item price summed to order
       grain, excluding freight.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN b.order_value IS NULL  THEN 'Unknown'
            WHEN b.order_value <  25    THEN 'R$0-25'
            WHEN b.order_value <  50    THEN 'R$25-50'
            WHEN b.order_value < 100    THEN 'R$50-100'
            WHEN b.order_value < 200    THEN 'R$100-200'
            WHEN b.order_value < 500    THEN 'R$200-500'
            ELSE                             'R$500+'
       END                                             AS price_bucket,
       COUNT(*)                                        AS review_count,
       CAST(AVG(f.review_score * 1.0) AS DECIMAL(4,2)) AS avg_score
FROM dbo.bridge_review_order b
JOIN dbo.fact_reviews f ON f.review_id = b.review_id
GROUP BY CASE WHEN b.order_value IS NULL  THEN 'Unknown'
              WHEN b.order_value <  25    THEN 'R$0-25'
              WHEN b.order_value <  50    THEN 'R$25-50'
              WHEN b.order_value < 100    THEN 'R$50-100'
              WHEN b.order_value < 200    THEN 'R$100-200'
              WHEN b.order_value < 500    THEN 'R$200-500'
              ELSE                             'R$500+'
         END
ORDER BY avg_score DESC;
GO


/* ----------------------------------------------------------------------------
   B6. PAGE 2 — Category x delivery outcome heatmap
       Reads bridge_review_category_delay, the pre-flattened standalone table.

       Averaging across two independent many-to-many bridges in one filter
       context (category via one, delay via the other) failed through three
       separate DAX approaches, each returning wrong-but-plausible numbers.
       Pre-flattening the join in SQL made the result deterministic, and these
       figures match the published matrix exactly.

       CAUTION: category_name_en exists on BOTH dim_product and this table,
       with no relationship between them. Dragging the wrong one into a visual
       makes every row render the identical grand total -- a bug that looks
       like a formatting problem, not a modelling one.

       These bucket averages differ slightly from B4 by design. B4 is at
       review x order grain; this table is at review x category x product
       grain, so multi-product reviews carry more weight here.
   ---------------------------------------------------------------------------- */
SELECT TOP 10
       category_name_en,
       COUNT(*)                                                            AS total_rows,
       CAST(AVG(CASE WHEN delay_bucket = 'On Time'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2))         AS on_time,
       CAST(AVG(CASE WHEN delay_bucket = '1-7 Days Late'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2))         AS late_1_7,
       CAST(AVG(CASE WHEN delay_bucket = '8-14 Days Late'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2))         AS late_8_14,
       CAST(AVG(CASE WHEN delay_bucket = '15+ Days Late'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2))         AS late_15_plus,
       CAST(AVG(CASE WHEN delay_bucket = 'Not Delivered'
                     THEN review_score * 1.0 END) AS DECIMAL(4,2))         AS not_delivered
FROM dbo.bridge_review_category_delay
WHERE category_name_en <> 'Unknown'
GROUP BY category_name_en
ORDER BY COUNT(*) DESC;
GO


/* ----------------------------------------------------------------------------
   B7. PAGE 3 — Seller KPIs
       [Top Seller Avg Score]     5.00   (min. 30 reviews)
       [Bottom Seller Avg Score]  2.33   (min. 30 reviews)

       Both KPIs respond to the page slicers, and the >= 30 threshold applies
       to the FILTERED review count -- so selecting a single year legitimately
       changes both figures and may drop sellers below the threshold. The card
       subtitles describe a rule, not a fixed cohort.

       The ranking is stable at this threshold: rank 10 (4.66) is clearly
       separated from ranks 11-12 (both 4.64), and no ties occur at the bottom
       cutoff either, so no secondary sort is required.
   ---------------------------------------------------------------------------- */
WITH seller_reviews AS (
    SELECT b.seller_id,
           COUNT(DISTINCT b.review_id) AS review_count,
           AVG(f.review_score * 1.0)   AS avg_score
    FROM dbo.bridge_review_seller b
    JOIN dbo.fact_reviews f ON f.review_id = b.review_id
    GROUP BY b.seller_id
    HAVING COUNT(DISTINCT b.review_id) >= 30
),
ranked AS (
    SELECT s.seller_id, s.review_count, s.avg_score,
           d.seller_state,
           ROW_NUMBER() OVER (ORDER BY s.avg_score DESC, s.review_count DESC) AS rn_top,
           ROW_NUMBER() OVER (ORDER BY s.avg_score ASC,  s.review_count DESC) AS rn_bottom
    FROM seller_reviews s
    LEFT JOIN dbo.dim_seller d ON d.seller_id = s.seller_id
)
SELECT CASE WHEN rn_top <= 10 THEN 'TOP' ELSE 'BOTTOM' END AS side,
       CASE WHEN rn_top <= 10 THEN rn_top ELSE rn_bottom END AS rank_pos,
       LEFT(seller_id, 8) + '...' AS seller_short,
       seller_state,
       review_count,
       CAST(avg_score AS DECIMAL(4,2)) AS avg_score
FROM ranked
WHERE rn_top <= 10 OR rn_bottom <= 10
ORDER BY side DESC, rank_pos;
GO


/* ----------------------------------------------------------------------------
   B8. PAGE 3 — Response time distribution
       [Avg Response Days]  2.58
       Buckets: 54,928 / 29,706 / 9,801 / 2,311 / 1,009 / 655. Maximum 518 days.

       Bucketed rather than plotted on a log scale, matching the histogram
       convention used in Portfolio #2. The decay is steep enough that the last
       three bars are near-invisible against the first -- that is the honest
       shape and it is left linear.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN response_days <=  1 THEN '0-1 days'
            WHEN response_days <=  3 THEN '2-3 days'
            WHEN response_days <=  7 THEN '4-7 days'
            WHEN response_days <= 14 THEN '8-14 days'
            WHEN response_days <= 30 THEN '15-30 days'
            ELSE                          '30+ days'
       END                                          AS response_bucket,
       COUNT(*)                                     AS review_count,
       CAST(100.0 * COUNT(*)
            / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_total
FROM dbo.fact_reviews
GROUP BY CASE WHEN response_days <=  1 THEN '0-1 days'
              WHEN response_days <=  3 THEN '2-3 days'
              WHEN response_days <=  7 THEN '4-7 days'
              WHEN response_days <= 14 THEN '8-14 days'
              WHEN response_days <= 30 THEN '15-30 days'
              ELSE                          '30+ days'
         END
ORDER BY MIN(response_days);

SELECT CAST(AVG(response_days * 1.0) AS DECIMAL(6,3)) AS avg_response_days,
       MAX(response_days)                             AS max_response_days
FROM dbo.fact_reviews;
GO


/* ----------------------------------------------------------------------------
   B9. PAGE 3 — Comment rate by review score
       Expect 77.32 / 68.66 / 44.65 / 32.84 / 38.08.

       A near-monotonic decline with a clear uptick at 5 stars: dissatisfied
       customers explain themselves, satisfied ones mostly do not, and the very
       happiest partly re-engage. This U-shape is why the 43.07% headline
       comment rate understates how much written signal sits in the 1-2 star
       bucket.

       [Pct No Comment] is defined as 1 - [Comment Rate] rather than as a
       has_comment = FALSE test. Both give 56.93% here, but the subtraction is
       immune by construction to the BLANK() = FALSE trap documented in B4, and
       it guarantees the two pages reconcile permanently.
   ---------------------------------------------------------------------------- */
SELECT review_score,
       COUNT(*)                                              AS reviews,
       SUM(CAST(has_comment AS INT))                         AS with_comment,
       CAST(100.0 * SUM(CAST(has_comment AS INT))
            / COUNT(*) AS DECIMAL(5,2))                      AS pct_with_comment
FROM dbo.fact_reviews
GROUP BY review_score
ORDER BY review_score;

-- Reconciliation: these two must sum to exactly 100.00.
SELECT CAST(100.0 * SUM(CAST(has_comment AS INT)) / COUNT(*) AS DECIMAL(5,2))     AS pct_with_comment,
       CAST(100.0 * SUM(1 - CAST(has_comment AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS pct_no_comment
FROM dbo.fact_reviews;
GO


/* ----------------------------------------------------------------------------
   B10. PAGE 1 — Response time callout
        Expect roughly 86% answered within 3 days, and 655 reviews (0.7%)
        waiting over 30 days, with the longest stretching past a year.
   ---------------------------------------------------------------------------- */
SELECT CAST(100.0 * SUM(CASE WHEN response_days <= 3  THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                       AS pct_within_3_days,
       SUM(CASE WHEN response_days > 30  THEN 1 ELSE 0 END)   AS over_30_days,
       CAST(100.0 * SUM(CASE WHEN response_days > 30 THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                       AS pct_over_30_days,
       SUM(CASE WHEN response_days > 365 THEN 1 ELSE 0 END)   AS over_1_year
FROM dbo.fact_reviews;
GO


/* ============================================================================
   END OF VALIDATION
   ============================================================================ */
