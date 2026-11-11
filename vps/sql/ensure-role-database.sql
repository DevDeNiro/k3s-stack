-- =============================================================================
-- Ensures a login role and its database (owned by the role, closed to the other
-- roles) exist.
-- Variables: role, password, database, reset_password (true | false)
--   reset_password=false never changes the password of an existing role.
-- Run as the postgres superuser through pg_admin_exec (scripts/lib/common.sh).
-- =============================================================================
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') AS role_missing \gset

\if :role_missing
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'password') \gexec
\elif :reset_password
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'password') \gexec
\endif

SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database') \gexec

-- PostgreSQL grants CONNECT and TEMPORARY on every new database to PUBLIC: any
-- other role could open a session in it. Only its owner connects (and the
-- postgres superuser, not concerned by privileges).
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'database') \gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'database', :'role') \gexec
