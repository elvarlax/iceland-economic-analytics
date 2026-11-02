-- ================================================================
-- Gold layer in Fabric Data Warehouse: schema and tables
-- Run once in the warehouse (wh_iceland_economy). Re-running is safe.
--
-- Kimball star schema with one conformed date dimension and one fact
-- table per grain:
--   dim_date                          one row per day (Power BI date table)
--   fact_economic_indicators_monthly  one row per month (periodic snapshot)
--   fact_gdp_quarterly                one row per quarter (periodic snapshot)
-- Each fact table holds one column per indicator, named with its unit.
-- Values are as published; NULL means not yet published for that month.
--
-- Fabric Warehouse has no nvarchar, tinyint or datetime: text is
-- varchar (UTF-8), small numbers are smallint, timestamps datetime2(6).
-- Keys are declared NOT ENFORCED: Fabric doesn't enforce them, so
-- integrity is checked by gold.validate_gold.
-- ================================================================

IF SCHEMA_ID('gold') IS NULL
    EXEC ('CREATE SCHEMA gold');
GO

-- One row per calendar day, 1980-01-01 to 2030-12-31. date_key = YYYYMMDD.
IF OBJECT_ID('gold.dim_date') IS NULL
CREATE TABLE gold.dim_date
(
    date_key          int          NOT NULL,
    full_date         date         NOT NULL,
    day_of_week_num   smallint     NOT NULL,  -- 1 = Sunday ... 7 = Saturday
    day_name          varchar(10)  NOT NULL,
    day_of_month      smallint     NOT NULL,
    day_of_year       smallint     NOT NULL,
    week_of_year      smallint     NOT NULL,  -- ISO week
    month_num         smallint     NOT NULL,
    month_name        varchar(10)  NOT NULL,
    month_short_name  varchar(3)   NOT NULL,
    quarter_num       smallint     NOT NULL,
    quarter_label     varchar(7)   NOT NULL,  -- e.g. 2023 Q3
    year_num          smallint     NOT NULL,
    year_month_key    int          NOT NULL,  -- YYYYMM
    is_weekday        bit          NOT NULL,
    is_weekend        bit          NOT NULL,
    is_month_start    bit          NOT NULL,
    is_month_end      bit          NOT NULL,
    is_quarter_start  bit          NOT NULL,
    is_quarter_end    bit          NOT NULL,
    is_year_start     bit          NOT NULL,
    is_year_end       bit          NOT NULL,
    analysis_period   varchar(20)  NOT NULL,  -- 2008-2011, 2020-2021, 2022-2026, Other
    is_analysis_period bit         NOT NULL,
    refreshed_at      datetime2(6) NOT NULL
);
GO

-- Monthly periodic snapshot. date_key = first day of the month.
IF OBJECT_ID('gold.fact_economic_indicators_monthly') IS NULL
CREATE TABLE gold.fact_economic_indicators_monthly
(
    date_key               int          NOT NULL,
    inflation_12m_pct      float        NULL,  -- CPI, 12-month change, % (9.25 = 9.25%)
    key_interest_rate_pct  float        NULL,  -- last value in the month, % per year
    unemployment_rate_pct  float        NULL,  -- Labour Force Survey, trend, %
    isk_per_eur            float        NULL,  -- monthly average of daily mid rates
    isk_per_usd            float        NULL,  -- monthly average of daily mid rates
    house_price_index      float        NULL,  -- Mar 2000 = 100
    wage_index             float        NULL,  -- Dec 1988 = 100
    row_created_at         datetime2(6) NOT NULL,
    row_updated_at         datetime2(6) NOT NULL
);
GO

-- Quarterly periodic snapshot. date_key = first day of the quarter.
IF OBJECT_ID('gold.fact_gdp_quarterly') IS NULL
CREATE TABLE gold.fact_gdp_quarterly
(
    date_key               int          NOT NULL,
    gdp_growth_yoy_pct     float        NOT NULL,  -- change from the same quarter a year earlier, %
    row_created_at         datetime2(6) NOT NULL,
    row_updated_at         datetime2(6) NOT NULL
);
GO

-- Data quality log: one row per validation run, plus one row per
-- gold.load_gold run that was rolled back (check columns NULL)
IF OBJECT_ID('gold.dq_logs') IS NULL
CREATE TABLE gold.dq_logs
(
    run_timestamp     datetime2(6)  NOT NULL,
    table_name        varchar(100)  NOT NULL,
    checks_run        int           NULL,
    checks_failed     int           NULL,
    status            varchar(10)   NOT NULL,  -- PASSED / FAILED
    failed_checks     varchar(4000) NULL
);
GO

-- Keys (NOT ENFORCED). Added only if missing, so the script can be re-run.
IF OBJECT_ID('gold.pk_dim_date') IS NULL
    ALTER TABLE gold.dim_date ADD CONSTRAINT pk_dim_date PRIMARY KEY NONCLUSTERED (date_key) NOT ENFORCED;
IF OBJECT_ID('gold.pk_fact_economic_indicators_monthly') IS NULL
    ALTER TABLE gold.fact_economic_indicators_monthly ADD CONSTRAINT pk_fact_economic_indicators_monthly PRIMARY KEY NONCLUSTERED (date_key) NOT ENFORCED;
IF OBJECT_ID('gold.pk_fact_gdp_quarterly') IS NULL
    ALTER TABLE gold.fact_gdp_quarterly ADD CONSTRAINT pk_fact_gdp_quarterly PRIMARY KEY NONCLUSTERED (date_key) NOT ENFORCED;
IF OBJECT_ID('gold.fk_monthly_date') IS NULL
    ALTER TABLE gold.fact_economic_indicators_monthly ADD CONSTRAINT fk_monthly_date FOREIGN KEY (date_key) REFERENCES gold.dim_date (date_key) NOT ENFORCED;
IF OBJECT_ID('gold.fk_quarterly_date') IS NULL
    ALTER TABLE gold.fact_gdp_quarterly ADD CONSTRAINT fk_quarterly_date FOREIGN KEY (date_key) REFERENCES gold.dim_date (date_key) NOT ENFORCED;
GO
