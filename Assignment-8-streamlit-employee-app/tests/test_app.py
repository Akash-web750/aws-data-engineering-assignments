"""
test_app.py - Scripted UI tests for streamlit_app.py.

Streamlit's AppTest runs the real app script without a browser. Snowflake is
replaced by FakeEmployeeTable, an in-memory table with the same four functions
the app calls in employee_repository, so these tests run offline and check the
UI flow: list, Edit buttons, filters, Add, Edit and validation errors.
"""

from datetime import date, datetime
from unittest import mock

import pandas as pd
import pytest
import streamlit as st
from streamlit.testing.v1 import AppTest

import employee_repository as repo
from conftest import PROJECT_DIR, make_employee

APP_FILE = str(PROJECT_DIR / "streamlit_app.py")


class FakeEmployeeTable:
    """In-memory stand-in for the EMPLOYEES table and the repository functions."""

    def __init__(self, rows):
        self.rows = rows
        self.next_id = max(row["EMPLOYEE_ID"] for row in rows) + 1

    def fetch_employees(self, session):
        """Return the current rows, like repo.fetch_employees."""
        employees = pd.DataFrame(self.rows)
        employees["CREATED_AT"] = datetime(2026, 10, 1)
        employees["UPDATED_AT"] = datetime(2026, 10, 1)
        return employees

    def email_exists(self, session, email, exclude_employee_id=None):
        """Return True if a different employee has this e-mail."""
        return any(
            row["EMAIL"] == email and row["EMPLOYEE_ID"] != exclude_employee_id
            for row in self.rows
        )

    def insert_employee(self, session, employee):
        """Append a row with the next ID and return that ID."""
        new_id = self.next_id
        self.next_id += 1
        self.rows.append({"EMPLOYEE_ID": new_id, **employee})
        return new_id

    def update_employee(self, session, employee_id, employee):
        """Overwrite the matching row and return how many rows changed."""
        for row in self.rows:
            if row["EMPLOYEE_ID"] == employee_id:
                row.update(employee)
                return 1
        return 0


@pytest.fixture
def table():
    """Three employees, and the repository patched to use them for one test."""
    fake = FakeEmployeeTable([
        make_employee(1001),
        make_employee(
            1002, FIRST_NAME="Vikram", LAST_NAME="Singh", GENDER="Male",
            DEPARTMENT="Sales", JOB_TITLE="Account Manager", WORK_LOCATION="Mumbai",
            SALARY=600000.0, SKILLS=["CRM"], IS_REMOTE=True,
        ),
        make_employee(
            1003, FIRST_NAME="Meera", LAST_NAME="Nair", DEPARTMENT="Finance",
            JOB_TITLE="Financial Analyst", SALARY=1500000.0, IS_ACTIVE=False,
        ),
    ])
    with mock.patch.multiple(
        repo,
        create_session=lambda: object(),   # the fake needs no real session
        fetch_employees=fake.fetch_employees,
        email_exists=fake.email_exists,
        insert_employee=fake.insert_employee,
        update_employee=fake.update_employee,
    ):
        yield fake
    # The app caches its session with st.cache_resource for the whole process.
    # Clear it so the placeholder session never reaches another test file.
    st.cache_resource.clear()


def start_app():
    """Run the app once and fail the test if the script raised an exception."""
    app = AppTest.from_file(APP_FILE, default_timeout=30).run()
    assert not app.exception
    return app


def edit_button_keys(app):
    """Return the keys of the Edit buttons currently on the page."""
    return [button.key for button in app.button if button.key and button.key.startswith("edit_")]


def button_labelled(app, label):
    """Find a button (including form submit buttons) by its label."""
    return next(button for button in app.button if button.label == label)


def metric_value(app, label):
    """Return the displayed value of the metric with this label."""
    return next(metric.value for metric in app.metric if metric.label == label)


ADD_BUTTON = "➕ Add Employee"


def submit_form(app, opener, submit_label):
    """
    Press a submit button inside the open dialog and rerun the app.

    In a browser, submitting a form inside st.dialog reruns only the dialog,
    which therefore stays open and handles the submit. AppTest always reruns
    the whole script, where the dialog exists only while its opening button
    reports a click. Clicking the opener again in the same run reproduces the
    browser behaviour: the dialog is drawn and receives the submitted values.
    """
    opener.click()
    button_labelled(app, submit_label).click().run()


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------
def test_every_employee_is_listed_with_its_own_edit_button(table):
    app = start_app()
    assert edit_button_keys(app) == ["edit_1001", "edit_1002", "edit_1003"]
    assert metric_value(app, "Employees in table") == "3"
    assert metric_value(app, "Matching filters") == "3"


def test_add_employee_button_is_present(table):
    app = start_app()
    assert button_labelled(app, ADD_BUTTON) is not None


def test_list_is_paged(table):
    # 12 employees with 10 rows per page: page 1 shows 10, page 2 shows 2.
    table.rows[:] = [make_employee(2000 + number) for number in range(12)]
    app = start_app()
    assert len(edit_button_keys(app)) == 10
    app.number_input(key="page_number").set_value(2).run()
    assert edit_button_keys(app) == ["edit_2010", "edit_2011"]


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------
def test_sidebar_filters_narrow_the_list_and_reset_restores_it(table):
    app = start_app()

    app.multiselect(key="flt_departments").set_value(["Sales"]).run()
    assert edit_button_keys(app) == ["edit_1002"]

    button_labelled(app, "Reset filters").click().run()
    assert edit_button_keys(app) == ["edit_1001", "edit_1002", "edit_1003"]


def test_status_and_search_filters(table):
    app = start_app()

    app.radio(key="flt_status").set_value("Inactive").run()
    assert edit_button_keys(app) == ["edit_1003"]

    app.radio(key="flt_status").set_value("All")
    app.text_input(key="flt_search").set_value("vikram").run()
    assert edit_button_keys(app) == ["edit_1002"]


def test_no_match_shows_a_message(table):
    app = start_app()
    app.text_input(key="flt_search").set_value("nobody").run()
    assert edit_button_keys(app) == []
    assert "No employees match" in app.info[0].value


# ---------------------------------------------------------------------------
# Add
# ---------------------------------------------------------------------------
def test_add_employee_inserts_a_row_and_the_list_shows_it(table):
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()

    # Fill every required field of the empty form.
    app.text_input(key="emp_new_first_name").set_value("Nisha")
    app.text_input(key="emp_new_last_name").set_value("Kapoor")
    app.text_input(key="emp_new_email").set_value("Nisha.Kapoor@Example.com")
    app.date_input(key="emp_new_date_of_birth").set_value(date(1995, 4, 2))
    app.radio(key="emp_new_gender").set_value("Female")
    app.selectbox(key="emp_new_department").set_value("Product")
    app.text_input(key="emp_new_job_title").set_value("Product Manager")
    app.selectbox(key="emp_new_work_location").set_value("Hyderabad")
    app.date_input(key="emp_new_hire_date").set_value(date(2026, 9, 1))
    app.number_input(key="emp_new_salary").set_value(1800000.0)
    app.number_input(key="emp_new_experience_years").set_value(7.5)
    app.multiselect(key="emp_new_skills").set_value(["Product Strategy", "SQL"])
    app.checkbox(key="emp_new_is_remote").set_value(True)
    app.text_area(key="emp_new_notes").set_value("Joined from a startup.")
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")
    assert not app.exception

    # The row reached the table with cleaned values...
    added = table.rows[-1]
    assert added["EMPLOYEE_ID"] == 1004
    assert added["EMAIL"] == "nisha.kapoor@example.com"
    assert added["SKILLS"] == ["Product Strategy", "SQL"]
    assert added["IS_ACTIVE"] is True and added["IS_REMOTE"] is True
    # ...and the page shows the confirmation and the new row.
    assert "Added employee 1004: Nisha Kapoor." in app.success[0].value
    assert "edit_1004" in edit_button_keys(app)
    assert metric_value(app, "Employees in table") == "4"


def test_invalid_add_shows_errors_and_writes_nothing(table):
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()

    # Submit the form without filling anything in.
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    assert len(table.rows) == 3
    message = app.error[0].value
    assert "First name is required." in message
    assert "Email is required." in message
    assert "Select a department." in message


def test_duplicate_email_is_rejected(table):
    app = start_app()
    button_labelled(app, ADD_BUTTON).click().run()

    app.text_input(key="emp_new_first_name").set_value("Nisha")
    app.text_input(key="emp_new_last_name").set_value("Kapoor")
    # This address already belongs to employee 1001.
    app.text_input(key="emp_new_email").set_value("employee1001@example.com")
    app.date_input(key="emp_new_date_of_birth").set_value(date(1995, 4, 2))
    app.radio(key="emp_new_gender").set_value("Female")
    app.selectbox(key="emp_new_department").set_value("Product")
    app.text_input(key="emp_new_job_title").set_value("Product Manager")
    app.selectbox(key="emp_new_work_location").set_value("Hyderabad")
    app.number_input(key="emp_new_salary").set_value(1800000.0)
    submit_form(app, button_labelled(app, ADD_BUTTON), "Add employee")

    assert len(table.rows) == 3
    assert "Another employee already uses this email." in app.error[0].value


# ---------------------------------------------------------------------------
# Edit
# ---------------------------------------------------------------------------
def test_edit_form_opens_with_the_current_values(table):
    app = start_app()
    app.button(key="edit_1002").click().run()

    assert app.text_input(key="emp_1002_first_name").value == "Vikram"
    assert app.selectbox(key="emp_1002_department").value == "Sales"
    assert app.radio(key="emp_1002_gender").value == "Male"
    assert app.number_input(key="emp_1002_salary").value == 600000.0
    assert app.multiselect(key="emp_1002_skills").value == ["CRM"]
    assert app.checkbox(key="emp_1002_is_remote").value is True


def test_edit_employee_updates_the_row_and_the_list_shows_it(table):
    app = start_app()
    app.button(key="edit_1002").click().run()

    app.selectbox(key="emp_1002_department").set_value("Marketing")
    app.number_input(key="emp_1002_salary").set_value(750000.0)
    app.checkbox(key="emp_1002_is_active").set_value(False)
    submit_form(app, app.button(key="edit_1002"), "Save changes")
    assert not app.exception

    # Only employee 1002 changed, and no row was added.
    edited = table.rows[1]
    assert len(table.rows) == 3
    assert edited["DEPARTMENT"] == "Marketing"
    assert edited["SALARY"] == 750000.0
    assert edited["IS_ACTIVE"] is False
    assert edited["FIRST_NAME"] == "Vikram"            # untouched fields are kept
    assert table.rows[0]["DEPARTMENT"] == "Engineering"

    # The page confirms the save and the reloaded list shows the new values.
    assert "Updated employee 1002: Vikram Singh." in app.success[0].value
    list_texts = [element.value for element in app.markdown]
    assert "Marketing" in list_texts
    assert "₹750,000" in list_texts
    assert metric_value(app, "Active (matching)") == "1"


def test_cancel_closes_the_form_without_saving(table):
    app = start_app()
    app.button(key="edit_1001").click().run()
    app.text_input(key="emp_1001_first_name").set_value("Changed")
    submit_form(app, app.button(key="edit_1001"), "Cancel")

    assert table.rows[0]["FIRST_NAME"] == "Asha"
    assert not app.success
