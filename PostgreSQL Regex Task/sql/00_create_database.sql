-- =============================================================================
-- Step 3B-1 / 00 - Create the database for the PostgreSQL Regex Task
-- =============================================================================
-- Run while connected to the maintenance database "postgres":
--   psql -X -v ON_ERROR_STOP=1 -d postgres -f sql/00_create_database.sql
--
-- Plain CREATE DATABASE on purpose: if the database already exists the script fails and changes
-- nothing. To rebuild, drop the database explicitly first.
--
-- ENCODING UTF8
--   Stores the RAW LOGS byte-exactly (294 rows contain non-ASCII characters).
-- LOCALE_PROVIDER builtin, BUILTIN_LOCALE C.UTF-8 (PostgreSQL 17)
--   Character classification used by regular expressions (\s, [[:alpha:]], upper/lower) follows
--   Unicode and does not depend on the Windows locale of the server, so later regex behaviour is
--   reproducible. LC_COLLATE/LC_CTYPE C keep the libc side locale-neutral as well.
-- =============================================================================

CREATE DATABASE postgresql_regex_task
    WITH TEMPLATE        = template0
         ENCODING        = 'UTF8'
         LOCALE_PROVIDER = 'builtin'
         BUILTIN_LOCALE  = 'C.UTF-8'
         LC_COLLATE      = 'C'
         LC_CTYPE        = 'C';

COMMENT ON DATABASE postgresql_regex_task IS
    'PostgreSQL Regex Task - RAW LOG input (Step 3B-1) and, later, the regex parser.';
