-- ================================================================
-- Gold layer in Fabric Data Warehouse: load procedures
-- Silver stays in the lakehouse (Spark). These procedures read it with
-- three-part names (lh_iceland_economy.silver.<table>), which works for
-- items in the same workspace once the lakehouse is added to the
-- warehouse's Explorer. Rename lh_iceland_economy if yours differs (it must be in the same workspace).
--
-- Every load is a MERGE on the grain key (date_key), so all procedures are
-- safe to re-run. Each MERGE reads its source straight from a CTE, so
-- no temp tables are needed. Run order: gold.load_gold (calls the rest).
-- ================================================================

-- ── dim_date ─────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE gold.load_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start date = '1980-01-01', @end date = '2030-12-31';
    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    -- Number spine without a recursive CTE: 10^5 rows covers the 18,628 days
    WITH digits AS (
        SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)
    ),
    numbers AS (
        SELECT a.n + 10 * b.n + 100 * c.n + 1000 * d.n + 10000 * e.n AS n
        FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits d CROSS JOIN digits e
    ),
    dates AS (
        SELECT DATEADD(day, n, @start) AS d
        FROM numbers
        WHERE n <= DATEDIFF(day, @start, @end)
    )
    MERGE gold.dim_date AS t
    USING (
        SELECT
            YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d)                       AS date_key,
            d                                                               AS full_date,
            CAST(DATEDIFF(day, '1900-01-07', d) % 7 + 1 AS smallint)        AS day_of_week_num,  -- 1900-01-07 was a Sunday
            CAST(DATENAME(weekday, d) AS varchar(10))                       AS day_name,
            CAST(DAY(d) AS smallint)                                        AS day_of_month,
            CAST(DATEPART(dayofyear, d) AS smallint)                        AS day_of_year,
            CAST(DATEPART(iso_week, d) AS smallint)                         AS week_of_year,
            CAST(MONTH(d) AS smallint)                                      AS month_num,
            CAST(DATENAME(month, d) AS varchar(10))                         AS month_name,
            CAST(LEFT(DATENAME(month, d), 3) AS varchar(3))                 AS month_short_name,
            CAST(DATEPART(quarter, d) AS smallint)                          AS quarter_num,
            CAST(CONCAT(YEAR(d), ' Q', DATEPART(quarter, d)) AS varchar(7)) AS quarter_label,
            CAST(YEAR(d) AS smallint)                                       AS year_num,
            YEAR(d) * 100 + MONTH(d)                                        AS year_month_key,
            CAST(CASE WHEN DATEDIFF(day, '1900-01-07', d) % 7 IN (0, 6) THEN 0 ELSE 1 END AS bit) AS is_weekday,
            CAST(CASE WHEN DATEDIFF(day, '1900-01-07', d) % 7 IN (0, 6) THEN 1 ELSE 0 END AS bit) AS is_weekend,
            CAST(CASE WHEN DAY(d) = 1 THEN 1 ELSE 0 END AS bit)             AS is_month_start,
            CAST(CASE WHEN d = EOMONTH(d) THEN 1 ELSE 0 END AS bit)         AS is_month_end,
            CAST(CASE WHEN DAY(d) = 1 AND MONTH(d) IN (1, 4, 7, 10) THEN 1 ELSE 0 END AS bit)  AS is_quarter_start,
            CAST(CASE WHEN d = EOMONTH(d) AND MONTH(d) IN (3, 6, 9, 12) THEN 1 ELSE 0 END AS bit) AS is_quarter_end,
            CAST(CASE WHEN DAY(d) = 1 AND MONTH(d) = 1 THEN 1 ELSE 0 END AS bit)   AS is_year_start,
            CAST(CASE WHEN DAY(d) = 31 AND MONTH(d) = 12 THEN 1 ELSE 0 END AS bit) AS is_year_end,
            CAST(CASE
                WHEN d BETWEEN '2008-01-01' AND '2011-12-31' THEN '2008-2011'
                WHEN d BETWEEN '2020-01-01' AND '2021-12-31' THEN '2020-2021'
                WHEN d BETWEEN '2022-01-01' AND '2026-12-31' THEN '2022-2026'
                ELSE 'Other'
            END AS varchar(20))                                             AS analysis_period,
            CAST(CASE
                WHEN d BETWEEN '2008-01-01' AND '2011-12-31'
                  OR d BETWEEN '2020-01-01' AND '2021-12-31'
                  OR d BETWEEN '2022-01-01' AND '2026-12-31' THEN 1 ELSE 0
            END AS bit)                                                     AS is_analysis_period,
            @now                                                            AS refreshed_at
        FROM dates
    ) AS s
        ON t.date_key = s.date_key
    -- Only the period labels can change; everything else follows from the date.
    -- Updating only changed rows keeps the Delta table (and Direct Lake) quiet.
    WHEN MATCHED AND (t.analysis_period <> s.analysis_period OR t.is_analysis_period <> s.is_analysis_period) THEN UPDATE SET
        t.analysis_period    = s.analysis_period,
        t.is_analysis_period = s.is_analysis_period,
        t.refreshed_at       = s.refreshed_at
    WHEN NOT MATCHED THEN INSERT (
        date_key, full_date, day_of_week_num, day_name, day_of_month, day_of_year,
        week_of_year, month_num, month_name, month_short_name, quarter_num, quarter_label,
        year_num, year_month_key, is_weekday, is_weekend, is_month_start, is_month_end,
        is_quarter_start, is_quarter_end, is_year_start, is_year_end,
        analysis_period, is_analysis_period, refreshed_at
    ) VALUES (
        s.date_key, s.full_date, s.day_of_week_num, s.day_name, s.day_of_month, s.day_of_year,
        s.week_of_year, s.month_num, s.month_name, s.month_short_name, s.quarter_num, s.quarter_label,
        s.year_num, s.year_month_key, s.is_weekday, s.is_weekend, s.is_month_start, s.is_month_end,
        s.is_quarter_start, s.is_quarter_end, s.is_year_start, s.is_year_end,
        s.analysis_period, s.is_analysis_period, s.refreshed_at
    );
END;
GO

-- ── fact_economic_indicators_monthly ─────────────────────────────
-- One CTE per indicator returns (year, month, metric, value); the rows
-- are pivoted to one row per month with one column per indicator.
-- Adding an indicator = one CTE, one column, one line in the pivot.
-- Rows are never deleted: if Silver drops a month, the old value stays.
CREATE OR ALTER PROCEDURE gold.load_fact_economic_indicators_monthly
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    WITH key_interest_rate AS (     -- last value in each month
        SELECT YEAR(date) AS year, MONTH(date) AS month, 'key_interest_rate' AS metric, value
        FROM (
            SELECT date, value,
                   ROW_NUMBER() OVER (PARTITION BY YEAR(date), MONTH(date) ORDER BY date DESC) AS rn
            FROM lh_iceland_economy.silver.central_bank_indicators
            WHERE metric = 'policy_rate'
        ) AS p
        WHERE rn = 1
    ),
    inflation AS (
        SELECT YEAR(date) AS year, MONTH(date) AS month, 'inflation' AS metric, value
        FROM lh_iceland_economy.silver.central_bank_indicators
        WHERE metric = 'cpi'
    ),
    exchange_rates AS (             -- monthly average of daily rates
        SELECT YEAR(date) AS year, MONTH(date) AS month, metric, AVG(value) AS value
        FROM lh_iceland_economy.silver.central_bank_indicators
        WHERE metric IN ('iskeur', 'iskusd')
        GROUP BY YEAR(date), MONTH(date), metric
    ),
    statistics_monthly AS (         -- hpi, wage_index, unemployment_rate
        SELECT year, month, metric, value
        FROM lh_iceland_economy.silver.statistics_monthly_indicators
    ),
    all_values AS (
        SELECT year, month, metric, value FROM key_interest_rate
        UNION ALL SELECT year, month, metric, value FROM inflation
        UNION ALL SELECT year, month, metric, value FROM exchange_rates
        UNION ALL SELECT year, month, metric, value FROM statistics_monthly
    ),
    monthly AS (
        SELECT
            year * 10000 + month * 100 + 1                                                       AS date_key,
            ROUND(MAX(CASE WHEN metric = 'inflation'         THEN value END), 2)                 AS inflation_12m_pct,
            ROUND(MAX(CASE WHEN metric = 'key_interest_rate' THEN value END), 2)                 AS key_interest_rate_pct,
            ROUND(MAX(CASE WHEN metric = 'unemployment_rate' THEN value END), 2)                 AS unemployment_rate_pct,
            ROUND(MAX(CASE WHEN metric = 'iskeur'            THEN value END), 4)                 AS isk_per_eur,
            ROUND(MAX(CASE WHEN metric = 'iskusd'            THEN value END), 4)                 AS isk_per_usd,
            ROUND(MAX(CASE WHEN metric = 'hpi'               THEN value END), 2)                 AS house_price_index,
            ROUND(MAX(CASE WHEN metric = 'wage_index'        THEN value END), 2)                 AS wage_index
        FROM all_values
        WHERE value IS NOT NULL
        GROUP BY year, month
    )
    MERGE gold.fact_economic_indicators_monthly AS t
    USING monthly AS s
        ON t.date_key = s.date_key
    -- Update only rows where a value changed (NULL-safe comparison)
    WHEN MATCHED AND (
           ISNULL(t.inflation_12m_pct,     -1e9) <> ISNULL(s.inflation_12m_pct,     -1e9)
        OR ISNULL(t.key_interest_rate_pct, -1e9) <> ISNULL(s.key_interest_rate_pct, -1e9)
        OR ISNULL(t.unemployment_rate_pct, -1e9) <> ISNULL(s.unemployment_rate_pct, -1e9)
        OR ISNULL(t.isk_per_eur,           -1e9) <> ISNULL(s.isk_per_eur,           -1e9)
        OR ISNULL(t.isk_per_usd,           -1e9) <> ISNULL(s.isk_per_usd,           -1e9)
        OR ISNULL(t.house_price_index,     -1e9) <> ISNULL(s.house_price_index,     -1e9)
        OR ISNULL(t.wage_index,            -1e9) <> ISNULL(s.wage_index,            -1e9)
    ) THEN UPDATE SET
        t.inflation_12m_pct     = s.inflation_12m_pct,
        t.key_interest_rate_pct = s.key_interest_rate_pct,
        t.unemployment_rate_pct = s.unemployment_rate_pct,
        t.isk_per_eur           = s.isk_per_eur,
        t.isk_per_usd           = s.isk_per_usd,
        t.house_price_index     = s.house_price_index,
        t.wage_index            = s.wage_index,
        t.row_updated_at        = @now
    WHEN NOT MATCHED THEN INSERT (
        date_key, inflation_12m_pct, key_interest_rate_pct, unemployment_rate_pct,
        isk_per_eur, isk_per_usd, house_price_index, wage_index, row_created_at, row_updated_at
    ) VALUES (
        s.date_key, s.inflation_12m_pct, s.key_interest_rate_pct, s.unemployment_rate_pct,
        s.isk_per_eur, s.isk_per_usd, s.house_price_index, s.wage_index, @now, @now
    );
END;
GO

-- ── fact_gdp_quarterly ───────────────────────────────────────────
-- date_key = first day of the quarter (Q1 -> January 1).
CREATE OR ALTER PROCEDURE gold.load_fact_gdp_quarterly
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    MERGE gold.fact_gdp_quarterly AS t
    USING (
        SELECT
            year * 10000 + ((q - 1) * 3 + 1) * 100 + 1 AS date_key,
            ROUND(value, 2)                             AS gdp_growth_yoy_pct
        FROM lh_iceland_economy.silver.gdp_indicators
        WHERE value IS NOT NULL
    ) AS s
        ON t.date_key = s.date_key
    WHEN MATCHED AND t.gdp_growth_yoy_pct <> s.gdp_growth_yoy_pct THEN UPDATE SET
        t.gdp_growth_yoy_pct = s.gdp_growth_yoy_pct,
        t.row_updated_at     = @now
    WHEN NOT MATCHED THEN INSERT (date_key, gdp_growth_yoy_pct, row_created_at, row_updated_at)
        VALUES (s.date_key, s.gdp_growth_yoy_pct, @now, @now);
END;
GO
