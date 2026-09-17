-- =============================================================================
-- Step 3B-3 / 09 - Field validators (Step 2 VAL-*, Step 3A section 10.2, Step 3B-2 VAL-IP)
-- =============================================================================
--   psql -X -v ON_ERROR_STOP=1 -d postgresql_regex_task -f sql/09_parser_validators.sql
--
-- Validators judge an already-extracted value. They never raise errors for bad input and never
-- change the value. Re-runnable (CREATE OR REPLACE).
-- =============================================================================

\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

-- VAL-ENT: known entity type, ignoring case and treating space / _ / - as equal ------------------
CREATE OR REPLACE FUNCTION log_regex.is_valid_entity_type(p_value text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM log_regex.ref_entity_type t
        WHERE t.entity_type = upper(regexp_replace(p_value, '[[:space:]_-]+', '_', 'g'))
    )
$$;

-- VAL-EML: ASCII address, one @, no leading/trailing/consecutive dots, dotted domain ------------
CREATE OR REPLACE FUNCTION log_regex.is_valid_email(p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_value ~ '^[A-Za-z0-9]([A-Za-z0-9._%+-]*[A-Za-z0-9_%+-])?@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
       AND strpos(p_value, '..') = 0
$$;

-- VAL-RES: relative path, Windows drive path, UNC path, or known scheme with a non-empty authority --
CREATE OR REPLACE FUNCTION log_regex.is_valid_resource(p_value text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT p_value ~ '^/'
        OR p_value ~ '^[A-Za-z]:\\'
        OR p_value ~ '^\\\\'
        OR (    p_value ~ '^[A-Za-z][A-Za-z0-9+.-]*://[^/]'
            AND EXISTS (SELECT 1
                        FROM log_regex.ref_resource_scheme s
                        WHERE s.scheme = lower(substring(p_value FROM '^([A-Za-z][A-Za-z0-9+.-]*)://'))))
$$;

-- VAL-TS: known shape, real calendar date and clock time (year-less shapes use p_assumed_year) ----
CREATE OR REPLACE FUNCTION log_regex.is_valid_timestamp(p_value text, p_assumed_year integer)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    s          log_regex.ref_timestamp_shape%ROWTYPE;
    m          text[];
    v_year     integer;
    v_month    integer;
    v_day      integer;
    v_hour     integer;
    v_minute   integer;
    v_second   integer;
    v_last_day integer;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    FOR s IN SELECT * FROM log_regex.ref_timestamp_shape ORDER BY match_order LOOP
        m := regexp_match(p_value, s.pattern);
        CONTINUE WHEN m IS NULL;
        IF s.is_epoch THEN
            RETURN true;
        END IF;

        v_year := CASE WHEN s.year_group IS NULL THEN p_assumed_year ELSE m[s.year_group]::integer END;
        IF s.month_name_group IS NOT NULL THEN
            SELECT n.month_no INTO v_month FROM log_regex.ref_month_name n WHERE n.month_abbr = m[s.month_name_group];
        ELSE
            v_month := m[s.month_group]::integer;
        END IF;
        v_day    := btrim(m[s.day_group])::integer;
        v_hour   := m[s.hour_group]::integer;
        v_minute := m[s.minute_group]::integer;
        v_second := CASE WHEN s.second_group IS NULL OR m[s.second_group] IS NULL THEN 0
                         ELSE m[s.second_group]::integer END;

        IF v_year NOT BETWEEN 1 AND 9999 OR v_month IS NULL OR v_month NOT BETWEEN 1 AND 12 THEN
            RETURN false;
        END IF;
        v_last_day := extract(day FROM make_date(v_year, v_month, 1) + interval '1 month' - interval '1 day')::integer;
        IF v_day NOT BETWEEN 1 AND v_last_day THEN
            RETURN false;
        END IF;
        IF s.ampm_group IS NOT NULL AND m[s.ampm_group] IS NOT NULL THEN
            IF v_hour NOT BETWEEN 1 AND 12 THEN
                RETURN false;
            END IF;
        ELSIF v_hour NOT BETWEEN 0 AND 23 THEN
            RETURN false;
        END IF;
        RETURN v_minute BETWEEN 0 AND 59 AND v_second BETWEEN 0 AND 59;
    END LOOP;
    RETURN false;
END;
$$;

-- VAL-GEO: decimal, hemisphere suffix/prefix or DMS, within range, hemisphere letter of the right axis --
CREATE OR REPLACE FUNCTION log_regex.is_valid_coordinate(p_value text, p_axis text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_limit   numeric := CASE p_axis WHEN 'latitude' THEN 90 WHEN 'longitude' THEN 180 END;
    v_letters text    := CASE p_axis WHEN 'latitude' THEN 'NS' WHEN 'longitude' THEN 'EW' END;
    m         text[];
BEGIN
    IF v_limit IS NULL THEN
        RAISE EXCEPTION 'p_axis must be latitude or longitude, got %', p_axis;
    END IF;
    IF p_value ~ '^-?[0-9]{1,3}([.][0-9]+)?$' THEN
        RETURN abs(p_value::numeric) <= v_limit;
    END IF;
    m := regexp_match(p_value, '^([0-9]{1,3}([.][0-9]+)?) ([NSEW])$');
    IF m IS NOT NULL THEN
        RETURN strpos(v_letters, m[3]) > 0 AND m[1]::numeric <= v_limit;
    END IF;
    m := regexp_match(p_value, '^([NSEW])([0-9]{1,3}([.][0-9]+)?)$');
    IF m IS NOT NULL THEN
        RETURN strpos(v_letters, m[1]) > 0 AND m[2]::numeric <= v_limit;
    END IF;
    -- DMS: degree sign U+00B0; minutes ' or U+2032; seconds " or U+2033; optional single spaces
    m := regexp_match(p_value, '^([0-9]{1,3})\u00B0 ?([0-9]{2})[''\u2032] ?([0-9]{2}([.][0-9]+)?)["\u2033] ?([NSEW])$');
    IF m IS NOT NULL THEN
        RETURN strpos(v_letters, m[5]) > 0
           AND m[1]::integer <= v_limit
           AND m[2]::integer < 60
           AND m[3]::numeric < 60;
    END IF;
    RETURN false;
END;
$$;

-- VAL-IP: exact rule verified in Step 3B-2 (docs/Step3B2_IP_Validation.md section 4) ---------------------
CREATE OR REPLACE FUNCTION log_regex.is_valid_ip(p_value text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT p_value ~ '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'
        OR (    p_value ~ '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3})?(%[0-9A-Za-z._~-]+)?$'
            AND pg_input_is_valid(split_part(p_value, '%', 1), 'inet'))
$$;

-- VAL-STS: HTTP code 100-599 (optional standard reason), known status word, or the check mark -----
CREATE OR REPLACE FUNCTION log_regex.is_valid_status(p_value text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    m text[];
BEGIN
    m := regexp_match(p_value, '^([0-9]{3})( (.+))?$');
    IF m IS NOT NULL THEN
        IF m[1]::integer NOT BETWEEN 100 AND 599 THEN
            RETURN false;
        END IF;
        RETURN m[3] IS NULL
            OR EXISTS (SELECT 1 FROM log_regex.ref_http_reason h
                       WHERE h.status_code = m[1]::integer AND h.reason = m[3]);
    END IF;
    RETURN p_value = U&'\2713'
        OR EXISTS (SELECT 1 FROM log_regex.ref_status_word w WHERE w.status_word = upper(p_value));
END;
$$;

-- Dispatcher: VALID / INVALID for a non-missing, non-placeholder, non-truncated value -------------
CREATE OR REPLACE FUNCTION log_regex.field_validity(p_field text, p_value text, p_assumed_year integer)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ok boolean;
BEGIN
    v_ok := CASE p_field
                WHEN 'entity_type'     THEN log_regex.is_valid_entity_type(p_value)
                WHEN 'email_address'   THEN log_regex.is_valid_email(p_value)
                WHEN 'resource_url'    THEN log_regex.is_valid_resource(p_value)
                WHEN 'event_timestamp' THEN log_regex.is_valid_timestamp(p_value, p_assumed_year)
                WHEN 'tool'            THEN true
                WHEN 'latitude'        THEN log_regex.is_valid_coordinate(p_value, 'latitude')
                WHEN 'longitude'       THEN log_regex.is_valid_coordinate(p_value, 'longitude')
                WHEN 'ip_address'      THEN log_regex.is_valid_ip(p_value)
                WHEN 'action_phrase'   THEN true
                WHEN 'status'          THEN log_regex.is_valid_status(p_value)
            END;
    IF v_ok IS NULL THEN
        RAISE EXCEPTION 'field_validity: unknown field % or NULL value', p_field;
    END IF;
    RETURN CASE WHEN v_ok THEN 'VALID' ELSE 'INVALID' END;
END;
$$;

COMMIT;
