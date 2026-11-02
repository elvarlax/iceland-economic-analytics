-- ================================================================
-- Gold layer in Fabric Data Warehouse: quality gate and run order
--
-- gold.validate_gold checks both fact tables: one row per grain,
-- keys on the right day, every key in dim_date, value ranges per
-- column, every indicator present, volume and completeness. It logs
-- the run to gold.dq_logs and raises an error if any check fails.
--
-- gold.load_gold runs every load and the checks in ONE transaction.
-- If a check fails, everything rolls back and Gold keeps the last
-- good data. This matters because a Direct Lake semantic model picks
-- up new Delta data on its own ("Keep your Direct Lake data up to
-- date" is on by default): stopping the pipeline before a refresh is
-- not enough, bad rows must never be committed.
-- ================================================================

CREATE OR ALTER PROCEDURE gold.validate_gold
AS
BEGIN
    SET NOCOUNT ON;

    -- Distributed (Parquet-backed) temp table: behaves like a user table
    CREATE TABLE #checks (check_name varchar(100) NOT NULL, failed_rows int NOT NULL)
    WITH (DISTRIBUTION = ROUND_ROBIN);

    -- 1. Grain: one row per month / per quarter
    INSERT INTO #checks
    SELECT 'monthly_unique_date_key', COUNT(*) FROM (
        SELECT date_key FROM gold.fact_economic_indicators_monthly GROUP BY date_key HAVING COUNT(*) > 1
    ) AS d;
    INSERT INTO #checks
    SELECT 'quarterly_unique_date_key', COUNT(*) FROM (
        SELECT date_key FROM gold.fact_gdp_quarterly GROUP BY date_key HAVING COUNT(*) > 1
    ) AS d;

    -- 2. Keys on the right day: first of the month / first of the quarter
    INSERT INTO #checks
    SELECT 'monthly_key_first_of_month', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE date_key % 100 <> 1;
    INSERT INTO #checks
    SELECT 'quarterly_key_first_of_quarter', COUNT(*) FROM gold.fact_gdp_quarterly
    WHERE date_key % 100 <> 1 OR (date_key / 100) % 100 NOT IN (1, 4, 7, 10);

    -- 3. Referential integrity (keys aren't enforced in Fabric)
    INSERT INTO #checks
    SELECT 'monthly_fk_date', COUNT(*) FROM gold.fact_economic_indicators_monthly AS f
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date AS d WHERE d.date_key = f.date_key);
    INSERT INTO #checks
    SELECT 'quarterly_fk_date', COUNT(*) FROM gold.fact_gdp_quarterly AS f
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date AS d WHERE d.date_key = f.date_key);

    -- 4. Value ranges per column (NULL = not yet published, allowed)
    INSERT INTO #checks
    SELECT 'range_inflation_12m_pct', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE inflation_12m_pct NOT BETWEEN -10 AND 100;
    INSERT INTO #checks
    SELECT 'range_key_interest_rate_pct', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE key_interest_rate_pct NOT BETWEEN 0 AND 30;
    INSERT INTO #checks
    SELECT 'range_unemployment_rate_pct', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE unemployment_rate_pct NOT BETWEEN 0 AND 30;
    INSERT INTO #checks
    SELECT 'range_isk_per_eur', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE isk_per_eur <= 50 OR isk_per_eur > 500;
    INSERT INTO #checks
    SELECT 'range_isk_per_usd', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE isk_per_usd NOT BETWEEN 30 AND 300;
    INSERT INTO #checks
    SELECT 'range_house_price_index', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE house_price_index NOT BETWEEN 50 AND 2000;
    INSERT INTO #checks
    SELECT 'range_wage_index', COUNT(*) FROM gold.fact_economic_indicators_monthly
    WHERE wage_index NOT BETWEEN 50 AND 2000;
    INSERT INTO #checks
    SELECT 'range_gdp_growth_yoy_pct', COUNT(*) FROM gold.fact_gdp_quarterly
    WHERE gdp_growth_yoy_pct NOT BETWEEN -30 AND 30;

    -- 5. Every indicator has data (catches a renamed or missing source series)
    INSERT INTO #checks
    SELECT CONCAT('has_data_', c.col), CASE WHEN c.n = 0 THEN 1 ELSE 0 END
    FROM (
        SELECT 'inflation_12m_pct'     AS col, COUNT(inflation_12m_pct)     AS n FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'key_interest_rate_pct', COUNT(key_interest_rate_pct) FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'unemployment_rate_pct', COUNT(unemployment_rate_pct) FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'isk_per_eur',           COUNT(isk_per_eur)           FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'isk_per_usd',           COUNT(isk_per_usd)           FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'house_price_index',     COUNT(house_price_index)     FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'wage_index',            COUNT(wage_index)            FROM gold.fact_economic_indicators_monthly
        UNION ALL SELECT 'gdp_growth_yoy_pct',    COUNT(gdp_growth_yoy_pct)    FROM gold.fact_gdp_quarterly
    ) AS c;

    -- 6. Volume: at least 10 years of months and quarters
    INSERT INTO #checks
    SELECT 'monthly_row_count_min_120', CASE WHEN COUNT(*) >= 120 THEN 0 ELSE 1 END
    FROM gold.fact_economic_indicators_monthly;
    INSERT INTO #checks
    SELECT 'quarterly_row_count_min_40', CASE WHEN COUNT(*) >= 40 THEN 0 ELSE 1 END
    FROM gold.fact_gdp_quarterly;

    -- 7. Completeness: some month has at least 6 of the 7 monthly indicators
    --    (indicators publish on different schedules, so the newest months are partial)
    INSERT INTO #checks
    SELECT 'monthly_completeness_6_of_7', CASE WHEN EXISTS (
        SELECT 1 FROM gold.fact_economic_indicators_monthly
        WHERE IIF(inflation_12m_pct     IS NULL, 0, 1) + IIF(key_interest_rate_pct IS NULL, 0, 1)
            + IIF(unemployment_rate_pct IS NULL, 0, 1) + IIF(isk_per_eur          IS NULL, 0, 1)
            + IIF(isk_per_usd           IS NULL, 0, 1) + IIF(house_price_index    IS NULL, 0, 1)
            + IIF(wage_index            IS NULL, 0, 1) >= 6
    ) THEN 0 ELSE 1 END;

    -- Log the run
    DECLARE @checks_run int, @checks_failed int, @failed varchar(4000);
    SELECT @checks_run = COUNT(*), @checks_failed = SUM(CASE WHEN failed_rows > 0 THEN 1 ELSE 0 END)
    FROM #checks;
    SELECT @failed = STRING_AGG(CONCAT(check_name, ' (', failed_rows, ')'), ', ')
    FROM #checks WHERE failed_rows > 0;

    INSERT INTO gold.dq_logs (run_timestamp, table_name, checks_run, checks_failed, status, failed_checks)
    VALUES (SYSUTCDATETIME(), 'gold.fact_*', @checks_run, @checks_failed,
            CASE WHEN @checks_failed = 0 THEN 'PASSED' ELSE 'FAILED' END, @failed);

    SELECT check_name, failed_rows FROM #checks ORDER BY check_name;
    DROP TABLE #checks;

    IF @checks_failed > 0
    BEGIN
        DECLARE @message varchar(2048) = CONCAT('Data quality failed: ', @failed, '. See gold.dq_logs.');
        THROW 50001, @message, 1;
    END;
END;
GO

-- ── Run everything in order, all or nothing ──────────────────────
-- dim_date first (the facts reference it), then the facts, then the gate.
-- On any error (load or check) the transaction rolls back, the failure is
-- logged after the rollback so the log row survives, and the error is
-- re-thrown so the pipeline activity fails.
CREATE OR ALTER PROCEDURE gold.load_gold
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC gold.load_dim_date;
        EXEC gold.load_fact_economic_indicators_monthly;
        EXEC gold.load_fact_gdp_quarterly;
        EXEC gold.validate_gold;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @error varchar(4000) = LEFT(ERROR_MESSAGE(), 4000);
        INSERT INTO gold.dq_logs (run_timestamp, table_name, checks_run, checks_failed, status, failed_checks)
        VALUES (SYSUTCDATETIME(), 'gold.load_gold', NULL, NULL, 'FAILED', CONCAT('Rolled back: ', @error));

        THROW;
    END CATCH;
END;
GO

-- First run. The transaction lives inside the procedure, so this works
-- in the Fabric query editor, where each Run is its own session:
-- EXEC gold.load_gold;
-- SELECT TOP 5 * FROM gold.dq_logs ORDER BY run_timestamp DESC;
