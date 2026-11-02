-- ================================================================
-- Gold layer in Fabric Data Warehouse: least-privilege roles
--
-- Workspace roles (Admin, Member, Contributor) see everything. Anyone
-- else who is given Read on the warehouse gets only what these SQL
-- roles grant:
--   gold_reader  reads the star schema (dim_date and both facts), not the
--                quality log
--   gold_loader  can run the load and nothing else; for a pipeline
--                identity or service principal
-- Re-running is safe.
-- ================================================================

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gold_reader')
    CREATE ROLE gold_reader;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gold_loader')
    CREATE ROLE gold_loader;
GO

-- Readers: every table and view in gold, except the operational log
GRANT SELECT ON SCHEMA::gold TO gold_reader;
DENY  SELECT ON gold.dq_logs TO gold_reader;
GO

-- Loader: run the load. Ownership chaining covers the gold tables, so
-- no direct table permissions are needed. The lakehouse is a separate
-- item, so the loader identity also needs Read on lh_iceland_economy.
GRANT EXECUTE ON gold.load_gold TO gold_loader;
GO

-- Add members by user, group or service principal (not stored in Git):
-- ALTER ROLE gold_reader ADD MEMBER [<user, group or app>];
-- ALTER ROLE gold_loader ADD MEMBER [<pipeline identity>];

-- Check what each role can do
SELECT pr.name AS role_name, pe.state_desc, pe.permission_name,
       pe.class_desc,
       CASE pe.class_desc
           WHEN 'SCHEMA' THEN SCHEMA_NAME(pe.major_id)
           WHEN 'OBJECT_OR_COLUMN' THEN OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id)
       END AS securable
FROM sys.database_permissions AS pe
JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name IN ('gold_reader', 'gold_loader')
ORDER BY pr.name, pe.permission_name;
