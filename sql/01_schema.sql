/* ============================================================================
   Portfolio #3 — Customer Experience & Satisfaction
   01_schema.sql   |   Star schema DDL
   Database: Olist_Retail   |   Schema: dbo   |   SQL Server (Docker)

   PURPOSE
     Creates the fact, bridge and flattened-analysis tables specific to the
     Customer Experience & Satisfaction dashboard.

   PREREQUISITES — created by Portfolio #1 / #2, NOT created here:
       dim_date        (2016-09-04 -> 2018-11-12, 800 rows, no gaps)
       dim_customer    (deduplicated on customer_unique_id)
       dim_seller
       dim_product
     These are reused UNMODIFIED. Portfolio #3 reads them; it never alters
     them. dim_date already covers the full review date range, so unlike
     Portfolio #2 no extension was required.

   RUN ORDER
       00_staging_prep.sql  -> staging tables from cleaned CSVs
       01_schema.sql        -> THIS FILE
       02_load_facts.sql    -> populate fact + bridge tables
       03_validation.sql    -> row counts and sanity checks

   EXPECTED ROW COUNTS AFTER FULL LOAD
       fact_reviews                    98,410
       bridge_review_order             99,224
       bridge_review_seller            99,549
       bridge_review_product          102,172
       bridge_review_category_delay   103,831
   ============================================================================ */

USE Olist_Retail;
GO


/* ----------------------------------------------------------------------------
   0. DROP IN DEPENDENCY ORDER (children before parents)
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.bridge_review_category_delay', 'U') IS NOT NULL
    DROP TABLE dbo.bridge_review_category_delay;
IF OBJECT_ID('dbo.bridge_review_product', 'U') IS NOT NULL
    DROP TABLE dbo.bridge_review_product;
IF OBJECT_ID('dbo.bridge_review_seller', 'U') IS NOT NULL
    DROP TABLE dbo.bridge_review_seller;
IF OBJECT_ID('dbo.bridge_review_order', 'U') IS NOT NULL
    DROP TABLE dbo.bridge_review_order;
IF OBJECT_ID('dbo.fact_reviews', 'U') IS NOT NULL
    DROP TABLE dbo.fact_reviews;
GO


/* ----------------------------------------------------------------------------
   1. fact_reviews
      Grain: ONE ROW PER review_id.

      Why review_id and not order_id: the Olist review data is genuinely
      many-to-many against orders (789 review_ids appear on more than one
      order; 547 orders carry more than one review, max 3). Forcing this to
      order grain would either duplicate or silently drop reviews, so orders
      are attached through bridge_review_order instead.

      has_comment collapses review_comment_title and review_comment_message
      into a single flag, because the title column is 88.3% blank and carries
      almost no independent signal.

      Text columns are deliberately bounded rather than NVARCHAR(MAX):
      MAX destroyed bulk-import throughput (~10 rows/sec, 10+ minutes for
      98K rows). Bounded to NVARCHAR(4000) the same import runs in ~41s.

      response_days = whole days from review creation to seller response.
      Verified: 0 nulls, 0 negatives, range 0-518 across all 98,410 rows.
      No filtering guard is needed on this column (unlike
      bridge_review_order.delivery_to_review_days -- see below).
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.fact_reviews (
    review_id               VARCHAR(32)     NOT NULL,
    review_score            TINYINT         NOT NULL,   -- 1..5
    has_comment             BIT             NULL,       -- title OR message present
    review_comment_title    NVARCHAR(200)   NULL,
    review_comment_message  NVARCHAR(4000)  NULL,
    -- role-playing date keys. creation is the ACTIVE relationship in the model,
    -- answer is INACTIVE and reached via USERELATIONSHIP() in DAX.
    creation_date_key       INT             NULL REFERENCES dim_date(date_key),
    answer_date_key         INT             NULL REFERENCES dim_date(date_key),
    response_days           INT             NULL,
    CONSTRAINT PK_fact_reviews PRIMARY KEY CLUSTERED (review_id)
);
GO


/* ----------------------------------------------------------------------------
   2. bridge_review_order
      Grain: review_id x order_id. Resolves the genuine many-to-many above.

      Also carries the order-level attributes the Drivers page needs, so that
      delivery outcome and order value can be sliced without a second hop.

      delivery_to_review_days: 5,127 rows are NEGATIVE (review created before
      the recorded delivery timestamp). Investigated and ruled out as a batch
      artifact -- only 56% fall within -7 days. Treated as unreliable timing
      data and EXCLUDED at measure level via a >= 0 filter, not deleted here,
      so the raw signal stays inspectable. This drops ~5.4% of reviews from
      the "days to review" measure only.

      order_value: 759 rows NULL. These are the known ~775 orders that were
      cancelled or went unavailable before fulfilment and therefore have zero
      rows in order_items. Bucketed as "Unknown" in the model and filtered out
      of the price chart rather than coerced to zero.

      is_late: NULLABLE ON PURPOSE. NULL means "never delivered, so lateness
      is undefined" -- distinct from FALSE ("delivered on time"). This matters:
      in DAX, BLANK() = FALSE evaluates to TRUE, so a naive
      [is_late] = FALSE test silently swept 2,865 never-delivered rows into
      the on-time bucket and moved the on-time average from 4.29 to 4.22.
      Every measure comparing this column to FALSE carries an explicit
      NOT ISBLANK() guard.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.bridge_review_order (
    review_id                    VARCHAR(32)    NOT NULL REFERENCES fact_reviews(review_id),
    order_id                     VARCHAR(32)    NOT NULL,
    order_status                 VARCHAR(20)    NULL,
    delivered_date_key           INT            NULL REFERENCES dim_date(date_key),
    estimated_delivery_date_key  INT            NULL REFERENCES dim_date(date_key),
    is_delivered                 BIT            NULL,
    is_late                      BIT            NULL,   -- NULL = never delivered
    delay_days                   INT            NULL,   -- +ve late, -ve early
    customer_unique_id           VARCHAR(50)    NULL REFERENCES dim_customer(customer_unique_id),
    delivery_to_review_days      INT            NULL,   -- 5,127 negatives, see above
    order_value                  DECIMAL(10,2)  NULL,   -- 759 NULLs, see above
    CONSTRAINT PK_bridge_review_order PRIMARY KEY CLUSTERED (review_id, order_id)
);
GO


/* ----------------------------------------------------------------------------
   3. bridge_review_seller
      Grain: review_id x seller_id.

      99,549 rows against 98,410 reviews: multi-seller orders mean one review
      can attach to several sellers. Per-seller aggregates are correct, but
      seller-level review counts do NOT sum to 98,410 across all sellers.
      Any "share of total reviews" measure at seller grain will therefore
      overstate slightly -- documented rather than silently corrected.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.bridge_review_seller (
    review_id  VARCHAR(32)  NOT NULL REFERENCES fact_reviews(review_id),
    seller_id  VARCHAR(50)  NOT NULL REFERENCES dim_seller(seller_id),
    CONSTRAINT PK_bridge_review_seller PRIMARY KEY CLUSTERED (review_id, seller_id)
);
GO


/* ----------------------------------------------------------------------------
   4. bridge_review_product
      Grain: review_id x product_id. Same rationale as the seller bridge --
      a multi-product order produces multiple rows per review.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.bridge_review_product (
    review_id   VARCHAR(32)  NOT NULL REFERENCES fact_reviews(review_id),
    product_id  VARCHAR(50)  NOT NULL REFERENCES dim_product(product_id),
    CONSTRAINT PK_bridge_review_product PRIMARY KEY CLUSTERED (review_id, product_id)
);
GO


/* ----------------------------------------------------------------------------
   5. bridge_review_category_delay
      DELIBERATE DENORMALISATION. Standalone, NO relationships, NO constraints.

      The category-by-delivery-outcome heatmap needs to cross two independent
      many-to-many bridges at once: category (via bridge_review_product ->
      dim_product) and delay bucket (via bridge_review_order). Three separate
      DAX approaches all returned wrong-but-plausible numbers -- the classic
      failure mode of averaging across two unrelated m2m paths in the same
      filter context.

      Resolution: pre-flatten the join in SQL. This table is intentionally
      disconnected in the Power BI model and is read only by the heatmap
      measures. Results are deterministic and match the validation queries
      exactly.

      Row count (103,831) legitimately exceeds fact_reviews because a review
      spanning several products in different categories produces one row per
      (review, category, delay bucket) combination.

      CAUTION: category_name_en also exists on dim_product. There is no
      relationship between these two tables, so dragging the wrong one into a
      visual makes every row render the identical grand total. Always confirm
      which table a field came from.
   ---------------------------------------------------------------------------- */
CREATE TABLE dbo.bridge_review_category_delay (
    review_id         VARCHAR(32)    NULL,
    category_name_en  NVARCHAR(100)  NULL,
    delay_bucket      VARCHAR(20)    NULL,
    review_score      TINYINT        NULL
);
GO

CREATE NONCLUSTERED INDEX IX_brcd_category_delay
    ON dbo.bridge_review_category_delay (category_name_en, delay_bucket)
    INCLUDE (review_score);
GO


/* ----------------------------------------------------------------------------
   6. NOTE ON MODEL RELATIONSHIPS (set in Power BI, not SQL)
   ----------------------------------------------------------------------------
   The REFERENCES clauses above are NOT decorative. Power BI reads foreign key
   constraints on load and creates model relationships from them even with
   autodetect disabled -- a missing REFERENCES clause shows up as a missing
   relationship in the model, which is easy to misdiagnose as a DAX problem.

   All three bridges -> fact_reviews: cross-filter direction MUST be set to
     "Both", not the default "Single". With Single, filters on seller, product
     or order never reach fact_reviews and every category renders the identical
     grand total. This bug appeared twice during the build before being caught.

   bridge_review_order -> dim_customer,
   bridge_review_product -> dim_product,
   bridge_review_seller  -> dim_seller: cross-filter "Both".

   fact_reviews[creation_date_key] -> dim_date: ACTIVE.
   All other date relationships (answer_date_key, delivered_date_key,
     estimated_delivery_date_key) are INACTIVE role-playing relationships,
     invoked with USERELATIONSHIP() in DAX as needed. Only one path from
     bridge_review_order to dim_date can be active at a time -- the direct
     relationship and the path through fact_reviews together form a loop.

   bridge_review_category_delay: STANDALONE. No relationships, by design.
     Do not connect it. See section 5.

   Calculated columns added in Power BI, not present in SQL:
     dim_date[Month Start Date], dim_seller[Seller Label],
     fact_reviews[Response Bucket] + [Response Bucket Sort],
     bridge_review_order[Delay Bucket] + [Price Bucket],
     bridge_review_category_delay[Bucket_Order]
   The two bucket columns place their ISBLANK() test FIRST in the SWITCH, so
   never-delivered and no-value rows are classified before any numeric
   comparison can silently absorb them.
   ---------------------------------------------------------------------------- */


/* ----------------------------------------------------------------------------
   7. POST-CREATE VERIFICATION
      Expect 5 tables, 10 foreign keys, 4 primary keys.
      bridge_review_category_delay has no PK and no FKs by design.
   ---------------------------------------------------------------------------- */
SELECT t.name AS table_name,
       (SELECT COUNT(*) FROM sys.foreign_keys fk
         WHERE fk.parent_object_id = t.object_id) AS fk_count,
       (SELECT COUNT(*) FROM sys.indexes i
         WHERE i.object_id = t.object_id AND i.is_primary_key = 1) AS pk_count
FROM sys.tables t
WHERE t.name IN ('fact_reviews','bridge_review_order','bridge_review_seller',
                 'bridge_review_product','bridge_review_category_delay')
ORDER BY t.name;
GO
