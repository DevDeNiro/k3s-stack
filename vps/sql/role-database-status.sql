-- =============================================================================
-- Prints "<role exists>|<database exists>" (true | false).
-- Variables: role, database
-- =============================================================================
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')::text
    || '|' ||
    EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database')::text;
