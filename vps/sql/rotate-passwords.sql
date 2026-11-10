-- =============================================================================
-- Rotates the infrastructure database passwords (scripts/setup-secrets.sh rotate).
-- Variables: postgres_password, keycloak_password
-- Run as the postgres superuser with the current password.
-- =============================================================================
SELECT format('ALTER ROLE postgres WITH PASSWORD %L', :'postgres_password') \gexec

SELECT format('ALTER ROLE keycloak WITH PASSWORD %L', :'keycloak_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak') \gexec
