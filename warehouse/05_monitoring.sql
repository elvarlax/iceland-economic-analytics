-- ================================================================
-- Gold layer in Fabric Data Warehouse: monitoring queries
-- Read-only. Query Insights keeps 30 days of history; new runs can
-- take a few minutes to appear.
-- ================================================================

-- 1. Latest quality-gate results (PASSED / FAILED, and rolled-back loads)
SELECT TOP 20 run_timestamp, table_name, checks_run, checks_failed, status, failed_checks
FROM gold.dq_logs
ORDER BY run_timestamp DESC;

-- 2. Every gold.load_gold run: when, how long, who started it, did it succeed
SELECT TOP 20
    submit_time,
    total_elapsed_time_ms / 1000.0 AS duration_seconds,
    status,
    error_code,
    login_name,
    program_name
FROM queryinsights.exec_requests_history
WHERE command LIKE '%EXEC%gold.load_gold%'
ORDER BY submit_time DESC;

-- 3. Slowest statements inside the load over the last 7 days
SELECT TOP 10
    LEFT(command, 120)                    AS statement_start,
    COUNT(*)                              AS runs,
    AVG(total_elapsed_time_ms)            AS avg_ms,
    MAX(total_elapsed_time_ms)            AS max_ms,
    SUM(data_scanned_remote_storage_mb)   AS remote_mb
FROM queryinsights.exec_requests_history
WHERE submit_time >= DATEADD(day, -7, SYSUTCDATETIME())
  AND (command LIKE '%MERGE gold.%' OR command LIKE '%gold.validate_gold%')
GROUP BY LEFT(command, 120)
ORDER BY avg_ms DESC;

-- 4. Failed statements in the warehouse over the last 7 days
SELECT TOP 20 submit_time, status, error_code, login_name, LEFT(command, 200) AS statement_start
FROM queryinsights.exec_requests_history
WHERE status = 'Failed'
  AND submit_time >= DATEADD(day, -7, SYSUTCDATETIME())
ORDER BY submit_time DESC;
