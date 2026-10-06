"""
test_live.py - End-to-end tests against the real Snowflake EMPLOYEES table.

Unlike test_app.py, nothing is mocked here: the real app script runs through
Streamlit's AppTest with a real Snowpark session, and every write is checked
by querying the table directly.

These tests are skipped unless EMP_APP_LIVE=1, so "pytest tests" stays offline
by default. To run them (PowerShell):

    $env:EMP_APP_LIVE = "1"
    $env:EMP_APP_CONNECTION = "<connection>"
    $env:EMP_APP_ROLE = "<role>"                 # optional
    $env:EMP_APP_WAREHOUSE = "EMPLOYEE_APP_WH"
    python -m pytest tests/test_live.py -v

The tests create one employee with the e-mail in TEST_EMAIL and then edit it.
Any row left by an earlier run is deleted first, so the table never holds
more than one test employee. The seeded employees are never modified; a test
checks that with a hash of those rows.
"""

import json
import os
from datetime import date

import pytest
import streamlit as st
from streamlit.testing.v1 import AppTest

import config
import employee_repository as repo
from conftest import PROJECT_DIR

# Skip the whole file unless live testing was requested.
pytestmark = pytest.mark.skipif(
    os.environ.get("EMP_APP_LIVE") != "1",
    reason="live Snowflake tests run only when EMP_APP_LIVE=1",
)

APP_FILE = str(PROJECT_DIR / "streamlit_app.py")
TABLE = config.EMPLOYEES_TABLE
EXPECTED_WAREHOUSE = "EMPLOYEE_APP_WH"

# The single employee these tests create and edit.
TEST_EMAIL = "live.test@example.com"
# An address that belongs to a seeded employee (sql/02_seed_sample_data.sql).
SEEDED_EMAIL = "aarav.sharma@example.com"
ADD_BUTTON = "➕ Add Employee"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def session():
    """One real Snowpark session for the file; removes a leftover test employee."""
    # Make sure the app opens a real session, not one cached by an earlier test file.
    st.cache_resource.clear()
    live_session = repo.create_session()
    live_session.sql(f"DELETE FROM {TABLE} WHERE EMAIL = ?", params=[TEST_EMAIL]).collect()
    yield live_session


def scalar(session, query, params=None):
    """Run a query and return the first column of its first row."""
    return session.sql(query, params=params or []).collect()[0][0]


def count_where(session, condition="TRUE"):
    """Count table rows that satisfy a SQL condition (the expected filter result)."""
    return scalar(session, f"SELECT COUNT(*) FROM {TABLE} WHERE {condition}")


def seeded_rows_hash(session):
    """Hash of every seeded row; it changes if any of those rows is modified."""
    return scalar(session, f"SELECT HASH_AGG(*) FROM {TABLE} WHERE EMAIL <> ?", [TEST_EMAIL])


def fetch_test_row(session):
    """Return the test employee straight from Snowflake as a dictionary, or None."""
    rows = session.sql(
        f"SELECT *, TO_JSON(SKILLS) AS SKILLS_JSON FROM {TABLE} WHERE EMAIL = ?",
        params=[TEST_EMAIL],
    ).collect()
    assert len(rows) <= 1, "more than one test employee in the table"
    return rows[0].as_dict() if rows else None


def start_app():
    """Run the app as a new browser session would and fail on any exception."""
    app = AppTest.from_file(APP_FILE, default_timeout=120).run()
    assert not app.exception, app.exception
    return app


def button_labelled(app, label):
    """Find a button (including form submit buttons) by its label."""
    return next(button for button in app.button if button.label == label)


def metric_value(app, label):
    """Return the displayed value of the metric with this label, as an integer."""
    return int(next(metric.value for metric in app.metric if metric.label == label))


def submit_form(app, opener, submit_label):
    """Submit the open dialog (see the same helper in test_app.py for why)."""
    opener.click()
    button_labelled(app, submit_label).click().run()
    assert not app.exception, app.exception


# ---------------------------------------------------------------------------
# Connection and SELECT
# ---------------------------------------------------------------------------
def test_session_uses_the_app_warehouse(session):
    assert scalar(session, "SELECT CURRENT_WAREHOUSE()") == EXPECTED_WAREHOUSE


def test_fetch_employees_returns_typed_rows(session):
    employees = repo.fetch_employees(session)

    # Every table row is returned, in EMPLOYEE_ID order.
    assert len(employees) == count_where(session)
    assert len(employees) >= 60
    assert employees["EMPLOYEE_ID"].is_monotonic_increasing

    # Each column arrives in the Python type the UI and filters rely on.
    first = employees.iloc[0]
    assert isinstance(first["SKILLS"], list) and all(isinstance(s, str) for s in first["SKILLS"])
    assert isinstance(first["DATE_OF_BIRTH"], date) and isinstance(first["HIRE_DATE"], date)
    assert isinstance(first["SALARY"], float) and isinstance(first["EXPERIENCE_YEARS"], float)
    assert employees["IS_ACTIVE"].dtype == bool and employees["IS_REMOTE"].dtype == bool

    # The SKILLS array survives the trip: same total number of skills as in Snowflake.
    assert employees["SKILLS"].apply(len).sum() == scalar(
        session, f"SELECT SUM(ARRAY_SIZE(SKILLS)) FROM {TABLE}"
    )


def test_email_exists_against_live_data(session):
    assert repo.email_exists(session, SEEDED_EMAIL) is True
    assert repo.email_exists(session, SEEDED_EMAIL.upper()) is True      # case-insensitive
    assert repo.email_exists(session, "nobody.here@example.com") is False


# ---------------------------------------------------------------------------
# List and filters
# ---------------------------------------------------------------------------
def test_list_shows_the_live_table(session):
    app = start_app()
    total = count_where(session)
    assert metric_value(app, "Employees in table") == total
    assert metric_value(app, "Matching filters") == total

    # First page: ten rows, each with its own Edit button, starting at the lowest ID.
    edit_keys = [b.key for b in app.button if b.key and b.key.startswith("edit_")]
    first_ids = [
        row[0] for row in session.sql(
            f"SELECT EMPLOYEE_ID FROM {TABLE} ORDER BY EMPLOYEE_ID LIMIT 10"
        ).collect()
    ]
    assert edit_keys == [f"edit_{employee_id}" for employee_id in first_ids]


@pytest.mark.parametrize(
    "widget, key, value, condition",
    [
        ("text_input", "flt_search", "sharma", "LOWER(FIRST_NAME || ' ' || LAST_NAME || ' ' || EMAIL || ' ' || JOB_TITLE) LIKE '%sharma%'"),
        ("multiselect", "flt_departments", ["Sales", "Finance"], "DEPARTMENT IN ('Sales', 'Finance')"),
        ("multiselect", "flt_types", ["Contract"], "EMPLOYMENT_TYPE = 'Contract'"),
        ("multiselect", "flt_locations", ["Pune", "Mumbai"], "WORK_LOCATION IN ('Pune', 'Mumbai')"),
        ("multiselect", "flt_genders", ["Female"], "GENDER = 'Female'"),
        ("multiselect", "flt_skills", ["SQL", "Snowflake"], "ARRAYS_OVERLAP(SKILLS, ARRAY_CONSTRUCT('SQL', 'Snowflake'))"),
        ("radio", "flt_status", "Inactive", "NOT IS_ACTIVE"),
        ("radio", "flt_status", "Active", "IS_ACTIVE"),
        ("checkbox", "flt_remote", True, "IS_REMOTE"),
        ("number_input", "flt_min_salary", 2000000.0, "SALARY >= 2000000"),
        ("number_input", "flt_max_salary", 500000.0, "SALARY <= 500000"),
        ("number_input", "flt_min_experience", 15.0, "EXPERIENCE_YEARS >= 15"),
        ("date_input", "flt_hired_from", date(2024, 1, 1), "HIRE_DATE >= '2024-01-01'"),
        ("date_input", "flt_hired_to", date(2015, 12, 31), "HIRE_DATE <= '2015-12-31'"),
    ],
)
def test_each_filter_matches_the_same_rows_as_sql(session, widget, key, value, condition):
    app = start_app()
    getattr(app, widget)(key=key).set_value(value).run()
    assert not app.exception, app.exception

    expected = count_where(session, condition)
    assert expected > 0, "the filter value should match at least one seeded row"
    assert metric_value(app, "Matching filters") == expected


def test_combined_filters_and_reset(session):
    app = start_app()
    app.multiselect(key="flt_departments").set_value(["Sales"])
    app.radio(key="flt_status").set_value("Active")
    app.number_input(key="flt_min_salary").set_value(1000000.0).run()
    assert metric_value(app, "Matching filters") == count_where(
        session, "DEPARTMENT = 'Sales' AND IS_ACTIVE AND SALARY >= 1000000"
    )

    button_labelled(app, "Reset filters").click().run()
    assert metric_value(app, "Matching filters") == count_where(session)


# ---------------------------------------------------------------------------
# Validation with live data
# ---------------------------------------------------------------------------
def fill_add_form(app, email):
    """Fill the Add form using every widget type; the caller submits it."""
    app.text_input(key="emp_new_first_name").set_value("  Livetest ")      # text input
    app.text_input(key="emp_new_last_name").set_value("Verification")
    app.text_input(key="emp_new_email").set_value(email)
    app.text_input(key="emp_new_phone").set_value("+91 98765 43210")
    app.date_input(key="emp_new_date_of_birth").set_value(date(1994, 2, 28))   # date input
    app.radio(key="emp_new_gender").set_value("Non-binary")                 # radio buttons
    app.selectbox(key="emp_new_department").set_value("Data & Analytics")   # select box
    app.text_input(key="emp_new_job_title").set_value("Data Engineer")
    app.selectbox(key="emp_new_work_location").set_value("Hyderabad")
    app.date_input(key="emp_new_hire_date").set_value(date(2026, 9, 15))
    app.radio(key="emp_new_employment_type").set_value("Contract")
    app.number_input(key="emp_new_salary").set_value(1234567.89)            # number input
    app.number_input(key="emp_new_experience_years").set_value(7.5)
    app.multiselect(key="emp_new_skills").set_value(["Snowflake", "SQL", "Python"])  # multi-select
    app.checkbox(key="emp_new_is_active").set_value(True)                   # checkbox
    app.checkbox(key="emp_new_is_remote").set_value(True)
    app.text_area(key="emp_new_notes").set_value("Created by the live test.\nSecond line.")  # text area


def test_empty_form_is_rejected_and_writes_nothing(session):
    rows_before = count_where(session)
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    assert "First name is required." in app.error[0].value
    assert count_where(session) == rows_before


def test_duplicate_email_is_rejected_by_the_live_check(session):
    rows_before = count_where(session)
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()
    # Upper case on purpose: the check must still find the seeded address.
    fill_add_form(app, SEEDED_EMAIL.upper())
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    assert "Another employee already uses this email." in app.error[0].value
    assert count_where(session) == rows_before


def test_invalid_values_are_rejected_and_write_nothing(session):
    rows_before = count_where(session)
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()
    fill_add_form(app, TEST_EMAIL)
    # Break three rules: bad phone, zero salary, and aged 16 on the hire date.
    app.text_input(key="emp_new_phone").set_value("12")
    app.number_input(key="emp_new_salary").set_value(0.0)
    app.date_input(key="emp_new_date_of_birth").set_value(date(2010, 1, 1))
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    message = app.error[0].value
    assert "Enter a valid phone number" in message
    assert "Salary must be greater than 0" in message
    assert "at least 18 years old" in message
    assert count_where(session) == rows_before
    assert fetch_test_row(session) is None


# ---------------------------------------------------------------------------
# Add, then Edit (these two tests run in this order)
# ---------------------------------------------------------------------------
def test_add_employee_inserts_the_row_in_snowflake(session):
    rows_before = count_where(session)
    seeded_before = seeded_rows_hash(session)

    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()
    fill_add_form(app, "Live.Test@Example.com")       # mixed case: stored in lower case
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    # --- The table holds exactly one new row with the submitted values -------
    row = fetch_test_row(session)
    assert row is not None
    assert count_where(session) == rows_before + 1
    assert row["EMPLOYEE_ID"] > scalar(session, f"SELECT MAX(EMPLOYEE_ID) FROM {TABLE} WHERE EMAIL <> ?", [TEST_EMAIL])
    assert row["FIRST_NAME"] == "Livetest"            # trimmed
    assert row["LAST_NAME"] == "Verification"
    assert row["EMAIL"] == TEST_EMAIL
    assert row["PHONE"] == "+91 98765 43210"
    assert row["GENDER"] == "Non-binary"
    assert row["DATE_OF_BIRTH"] == date(1994, 2, 28)
    assert row["DEPARTMENT"] == "Data & Analytics"
    assert row["JOB_TITLE"] == "Data Engineer"
    assert row["EMPLOYMENT_TYPE"] == "Contract"
    assert row["WORK_LOCATION"] == "Hyderabad"
    assert row["HIRE_DATE"] == date(2026, 9, 15)
    assert float(row["SALARY"]) == 1234567.89
    assert float(row["EXPERIENCE_YEARS"]) == 7.5
    assert json.loads(row["SKILLS_JSON"]) == ["Snowflake", "SQL", "Python"]
    assert row["IS_ACTIVE"] is True and row["IS_REMOTE"] is True
    assert row["NOTES"] == "Created by the live test.\nSecond line."
    assert row["CREATED_AT"] == row["UPDATED_AT"]
    assert seeded_rows_hash(session) == seeded_before  # no other row was touched

    # --- The app shows the latest data straight after the save ---------------
    new_id = row["EMPLOYEE_ID"]
    assert f"Added employee {new_id}: Livetest Verification." in app.success[0].value
    assert metric_value(app, "Employees in table") == rows_before + 1

    # A new browser session finds the new employee through the filters.
    fresh = start_app()
    fresh.text_input(key="flt_search").set_value("livetest").run()
    assert [b.key for b in fresh.button if b.key and b.key.startswith("edit_")] == [f"edit_{new_id}"]


def test_edit_employee_updates_the_row_in_snowflake(session):
    before = fetch_test_row(session)
    assert before is not None, "run test_add_employee_inserts_the_row_in_snowflake first"
    employee_id = before["EMPLOYEE_ID"]
    prefix = f"emp_{employee_id}"
    rows_before = count_where(session)
    seeded_before = seeded_rows_hash(session)

    app = start_app()
    app.text_input(key="flt_search").set_value("livetest").run()
    app.button(key=f"edit_{employee_id}").click().run()

    # --- The form opens with the values stored in Snowflake -------------------
    assert app.text_input(key=f"{prefix}_first_name").value == "Livetest"
    assert app.text_input(key=f"{prefix}_email").value == TEST_EMAIL
    assert app.date_input(key=f"{prefix}_date_of_birth").value == date(1994, 2, 28)
    assert app.radio(key=f"{prefix}_gender").value == "Non-binary"
    assert app.selectbox(key=f"{prefix}_department").value == "Data & Analytics"
    assert app.number_input(key=f"{prefix}_salary").value == 1234567.89
    assert app.multiselect(key=f"{prefix}_skills").value == ["Snowflake", "SQL", "Python"]
    assert app.checkbox(key=f"{prefix}_is_remote").value is True
    assert app.text_area(key=f"{prefix}_notes").value == "Created by the live test.\nSecond line."

    # --- Change one widget of every type and save -----------------------------
    app.text_input(key=f"{prefix}_job_title").set_value("Senior Data Engineer")      # text input
    app.number_input(key=f"{prefix}_salary").set_value(1500000.0)                    # number input
    app.selectbox(key=f"{prefix}_department").set_value("Engineering")               # select box
    app.multiselect(key=f"{prefix}_skills").set_value(["AWS", "Snowflake"])          # multi-select
    app.checkbox(key=f"{prefix}_is_active").set_value(False)                         # checkbox
    app.date_input(key=f"{prefix}_hire_date").set_value(date(2026, 10, 1))           # date input
    app.radio(key=f"{prefix}_employment_type").set_value("Full-time")                # radio buttons
    app.text_area(key=f"{prefix}_notes").set_value("")                               # text area -> NULL
    submit_form(app, app.button(key=f"edit_{employee_id}"), "Save changes")

    # --- The same row changed in Snowflake; nothing was inserted --------------
    after = fetch_test_row(session)
    assert count_where(session) == rows_before
    assert after["EMPLOYEE_ID"] == employee_id
    assert after["JOB_TITLE"] == "Senior Data Engineer"
    assert float(after["SALARY"]) == 1500000.0
    assert after["DEPARTMENT"] == "Engineering"
    assert json.loads(after["SKILLS_JSON"]) == ["AWS", "Snowflake"]
    assert after["IS_ACTIVE"] is False
    assert after["HIRE_DATE"] == date(2026, 10, 1)
    assert after["EMPLOYMENT_TYPE"] == "Full-time"
    assert after["NOTES"] is None
    # Fields that were not edited keep their values.
    assert after["FIRST_NAME"] == "Livetest" and after["EMAIL"] == TEST_EMAIL
    assert after["DATE_OF_BIRTH"] == date(1994, 2, 28) and after["IS_REMOTE"] is True
    # Timestamps: created is unchanged, updated moved forward.
    assert after["CREATED_AT"] == before["CREATED_AT"]
    assert after["UPDATED_AT"] > before["UPDATED_AT"]
    assert seeded_rows_hash(session) == seeded_before  # no other row was touched

    # --- The app shows the latest data ----------------------------------------
    assert f"Updated employee {employee_id}: Livetest Verification." in app.success[0].value
    fresh = start_app()
    fresh.multiselect(key="flt_departments").set_value(["Engineering"])
    fresh.radio(key="flt_status").set_value("Inactive").run()
    assert [b.key for b in fresh.button if b.key and b.key.startswith("edit_")] == [f"edit_{employee_id}"]
    fresh.button(key=f"edit_{employee_id}").click().run()
    assert fresh.number_input(key=f"{prefix}_salary").value == 1500000.0
    assert fresh.multiselect(key=f"{prefix}_skills").value == ["AWS", "Snowflake"]


def test_editing_to_another_employees_email_is_rejected(session):
    before = fetch_test_row(session)
    employee_id = before["EMPLOYEE_ID"]

    app = start_app()
    app.text_input(key="flt_search").set_value("livetest").run()
    app.button(key=f"edit_{employee_id}").click().run()
    app.text_input(key=f"emp_{employee_id}_email").set_value(SEEDED_EMAIL)
    submit_form(app, app.button(key=f"edit_{employee_id}"), "Save changes")

    assert "Another employee already uses this email." in app.error[0].value
    assert fetch_test_row(session)["UPDATED_AT"] == before["UPDATED_AT"]   # nothing was written
