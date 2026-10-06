"""
employee_repository.py - All Snowflake access for the Employee Manager app.

Every SQL statement the app runs lives here: opening the session, reading the
EMPLOYEES table, inserting a new employee and updating an existing one.
All statements use bind variables (?), so user input never becomes SQL text.
"""

import json
import os

import pandas as pd

import config

# Editable columns, in the order used by the INSERT and UPDATE statements.
# SKILLS is handled separately because it needs PARSE_JSON.
_SCALAR_COLUMNS = [
    "FIRST_NAME",
    "LAST_NAME",
    "EMAIL",
    "PHONE",
    "GENDER",
    "DATE_OF_BIRTH",
    "DEPARTMENT",
    "JOB_TITLE",
    "EMPLOYMENT_TYPE",
    "WORK_LOCATION",
    "HIRE_DATE",
    "SALARY",
    "EXPERIENCE_YEARS",
    "IS_ACTIVE",
    "IS_REMOTE",
    "NOTES",
]

# Separator used to move the SKILLS array through a single text column.
_SKILL_SEPARATOR = "|"


def create_session():
    """
    Return a Snowpark session.

    Inside Streamlit in Snowflake the platform provides an active session.
    When the app is run locally there is none, so a session is built from a
    Snowflake CLI connection named by EMP_APP_CONNECTION (default "default"),
    optionally with the role named by EMP_APP_ROLE and the warehouse named by
    EMP_APP_WAREHOUSE (each overrides the value stored in the connection).
    """
    from snowflake.snowpark import Session
    from snowflake.snowpark.context import get_active_session
    from snowflake.snowpark.exceptions import SnowparkSessionException

    try:
        # Normal path: running inside Snowflake.
        return get_active_session()
    except SnowparkSessionException:
        # Local development path: connect with a named CLI connection.
        settings = {"connection_name": os.environ.get("EMP_APP_CONNECTION", "default")}
        if os.environ.get("EMP_APP_ROLE"):
            settings["role"] = os.environ["EMP_APP_ROLE"]
        # Lets a local run use the app's own warehouse (EMPLOYEE_APP_WH) even
        # when the connection's default warehouse is a different one.
        if os.environ.get("EMP_APP_WAREHOUSE"):
            settings["warehouse"] = os.environ["EMP_APP_WAREHOUSE"]
        return Session.builder.configs(settings).create()


def fetch_employees(session):
    """
    Read every employee and return a pandas DataFrame, ordered by EMPLOYEE_ID.

    The numeric columns are cast to FLOAT so pandas receives plain floats
    instead of Decimal objects, and the SKILLS array is returned as text and
    split back into a Python list per row.
    """
    query = f"""
        SELECT
            EMPLOYEE_ID,
            FIRST_NAME,
            LAST_NAME,
            EMAIL,
            PHONE,
            GENDER,
            DATE_OF_BIRTH,
            DEPARTMENT,
            JOB_TITLE,
            EMPLOYMENT_TYPE,
            WORK_LOCATION,
            HIRE_DATE,
            SALARY::FLOAT            AS SALARY,
            EXPERIENCE_YEARS::FLOAT  AS EXPERIENCE_YEARS,
            ARRAY_TO_STRING(SKILLS, '{_SKILL_SEPARATOR}') AS SKILLS,
            IS_ACTIVE,
            IS_REMOTE,
            NOTES,
            CREATED_AT,
            UPDATED_AT
        FROM {config.EMPLOYEES_TABLE}
        ORDER BY EMPLOYEE_ID
    """
    employees = session.sql(query).to_pandas()

    # Make the column types predictable for the UI and the filter logic.
    employees["EMPLOYEE_ID"] = employees["EMPLOYEE_ID"].astype(int)
    employees["SKILLS"] = employees["SKILLS"].apply(
        lambda text: text.split(_SKILL_SEPARATOR) if text else []
    )
    employees["IS_ACTIVE"] = employees["IS_ACTIVE"].astype(bool)
    employees["IS_REMOTE"] = employees["IS_REMOTE"].astype(bool)
    # Dates become datetime.date objects whichever type the driver returned.
    for column in ("DATE_OF_BIRTH", "HIRE_DATE"):
        employees[column] = pd.to_datetime(employees[column]).dt.date
    return employees


def email_exists(session, email, exclude_employee_id=None):
    """
    Return True if another employee already uses this e-mail address.

    Snowflake does not enforce UNIQUE constraints on standard tables, so the
    app calls this before every insert and update. When editing, the employee
    being edited is excluded so keeping their own e-mail is allowed.
    """
    query = f"SELECT COUNT(*) FROM {config.EMPLOYEES_TABLE} WHERE LOWER(EMAIL) = ?"
    params = [email.lower()]
    if exclude_employee_id is not None:
        query += " AND EMPLOYEE_ID <> ?"
        params.append(int(exclude_employee_id))
    return session.sql(query, params=params).collect()[0][0] > 0


def _scalar_values(employee):
    """Return the employee's scalar values in _SCALAR_COLUMNS order, ready to bind."""
    values = []
    for column in _SCALAR_COLUMNS:
        value = employee[column]
        # Bind numbers as plain floats so the driver never sees numpy types.
        if column in ("SALARY", "EXPERIENCE_YEARS"):
            value = float(value)
        values.append(value)
    return values


def insert_employee(session, employee):
    """
    Insert one new employee and return the generated EMPLOYEE_ID.

    EMPLOYEE_ID, CREATED_AT and UPDATED_AT are filled by column defaults.
    INSERT ... SELECT is used (not VALUES) because PARSE_JSON, which turns the
    skills JSON text into an ARRAY, is not allowed in a VALUES clause.
    """
    columns = ", ".join(_SCALAR_COLUMNS + ["SKILLS"])
    placeholders = ", ".join(["?"] * len(_SCALAR_COLUMNS))
    statement = f"""
        INSERT INTO {config.EMPLOYEES_TABLE} ({columns})
        SELECT {placeholders}, PARSE_JSON(?)::ARRAY
    """
    params = _scalar_values(employee) + [json.dumps(employee["SKILLS"])]
    session.sql(statement, params=params).collect()

    # E-mail is unique, so it identifies the row that was just inserted.
    id_query = f"SELECT MAX(EMPLOYEE_ID) FROM {config.EMPLOYEES_TABLE} WHERE EMAIL = ?"
    return int(session.sql(id_query, params=[employee["EMAIL"]]).collect()[0][0])


def update_employee(session, employee_id, employee):
    """
    Update one existing employee and return the number of rows changed.

    Every editable column is rewritten and UPDATED_AT is set to now.
    A return value of 0 means the employee no longer exists.
    """
    assignments = ", ".join(f"{column} = ?" for column in _SCALAR_COLUMNS)
    statement = f"""
        UPDATE {config.EMPLOYEES_TABLE}
        SET {assignments},
            SKILLS = PARSE_JSON(?)::ARRAY,
            UPDATED_AT = CURRENT_TIMESTAMP()
        WHERE EMPLOYEE_ID = ?
    """
    params = _scalar_values(employee) + [json.dumps(employee["SKILLS"]), int(employee_id)]
    result = session.sql(statement, params=params).collect()
    # The first column of an UPDATE result is "number of rows updated".
    return int(result[0][0])
