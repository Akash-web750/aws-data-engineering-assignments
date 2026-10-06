"""
test_validation.py - Unit tests for validation.py.

Checks that form input is cleaned correctly and that every validation rule
accepts good data and rejects bad data. Runs offline: no Snowflake needed.
"""

from datetime import date

import pytest

import validation
from conftest import make_employee

# A fixed "today" so the date rules give the same result whenever the tests run.
TODAY = date(2026, 10, 6)


def errors_for(**overrides):
    """Clean and validate one employee with the given values changed."""
    cleaned = validation.clean_employee(make_employee(1, **overrides))
    return validation.validate_employee(cleaned, today=TODAY)


# ---------------------------------------------------------------------------
# clean_employee
# ---------------------------------------------------------------------------
def test_clean_trims_text_and_lowercases_email():
    cleaned = validation.clean_employee(make_employee(
        1, FIRST_NAME="  Asha  ", LAST_NAME=" Rao   Kumar ", EMAIL="  Asha.Rao@Example.COM ",
    ))
    assert cleaned["FIRST_NAME"] == "Asha"
    assert cleaned["LAST_NAME"] == "Rao Kumar"       # inner spaces collapsed
    assert cleaned["EMAIL"] == "asha.rao@example.com"


def test_clean_turns_empty_optional_text_into_none():
    cleaned = validation.clean_employee(make_employee(1, PHONE="   ", NOTES=""))
    assert cleaned["PHONE"] is None
    assert cleaned["NOTES"] is None


def test_clean_removes_duplicate_skills_and_keeps_order():
    cleaned = validation.clean_employee(make_employee(1, SKILLS=["SQL", "Python", "SQL"]))
    assert cleaned["SKILLS"] == ["SQL", "Python"]


def test_clean_does_not_include_generated_columns():
    # EMPLOYEE_ID and the timestamps are set by the database, never by the form.
    cleaned = validation.clean_employee(make_employee(1))
    assert "EMPLOYEE_ID" not in cleaned


# ---------------------------------------------------------------------------
# validate_employee: valid data
# ---------------------------------------------------------------------------
def test_valid_employee_has_no_errors():
    assert errors_for() == []


@pytest.mark.parametrize("name", ["Anne-Marie", "O'Brien", "Mary Ann", "José", "Rao Jr."])
def test_realistic_names_are_accepted(name):
    assert errors_for(FIRST_NAME=name) == []


def test_phone_is_optional():
    assert errors_for(PHONE="") == []


def test_no_skills_is_allowed():
    assert errors_for(SKILLS=[]) == []


# ---------------------------------------------------------------------------
# validate_employee: each rule rejects bad data
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "overrides, expected",
    [
        ({"FIRST_NAME": ""}, "First name is required."),
        ({"LAST_NAME": "   "}, "Last name is required."),
        ({"FIRST_NAME": "R2D2"}, "First name may contain only letters"),
        ({"LAST_NAME": "Rao;DROP"}, "Last name may contain only letters"),
        ({"JOB_TITLE": ""}, "Job title is required."),
        ({"EMAIL": ""}, "Email is required."),
        ({"EMAIL": "not-an-email"}, "Enter a valid email address."),
        ({"EMAIL": "a b@example.com"}, "Enter a valid email address."),
        ({"EMAIL": "asha@example"}, "Enter a valid email address."),
        ({"PHONE": "12345"}, "Enter a valid phone number"),
        ({"PHONE": "phone me"}, "Enter a valid phone number"),
        ({"GENDER": None}, "Select a gender."),
        ({"DEPARTMENT": None}, "Select a department."),
        ({"EMPLOYMENT_TYPE": None}, "Select an employment type."),
        ({"WORK_LOCATION": None}, "Select a work location."),
        ({"DATE_OF_BIRTH": None}, "Date of birth is required."),
        ({"HIRE_DATE": None}, "Hire date is required."),
        ({"SALARY": 0.0}, "Salary must be greater than 0"),
        ({"SALARY": 100_000_001.0}, "Salary must be greater than 0"),
        ({"EXPERIENCE_YEARS": -1.0}, "Experience must be between 0 and 50 years."),
        ({"EXPERIENCE_YEARS": 50.5}, "Experience must be between 0 and 50 years."),
        ({"SKILLS": [f"Skill {number}" for number in range(11)]}, "Select at most 10 skills."),
        ({"NOTES": "x" * 1001}, "Notes must be 1000 characters or fewer."),
    ],
)
def test_rule_rejects_bad_value(overrides, expected):
    errors = errors_for(**overrides)
    # Exactly one rule should fail, and it should be the expected one.
    assert len(errors) == 1
    assert errors[0].startswith(expected)


def test_employee_must_be_18_on_hire_date():
    # Born 2005-06-15: still 17 on 2023-06-14, 18 on 2023-06-15.
    too_young = errors_for(DATE_OF_BIRTH=date(2005, 6, 15), HIRE_DATE=date(2023, 6, 14))
    assert too_young == ["Employee must be at least 18 years old on the hire date."]
    assert errors_for(DATE_OF_BIRTH=date(2005, 6, 15), HIRE_DATE=date(2023, 6, 15)) == []


def test_hire_date_may_be_at_most_90_days_ahead():
    # 90 days after 2026-10-06 is 2027-01-04.
    assert errors_for(HIRE_DATE=date(2027, 1, 4)) == []
    assert errors_for(HIRE_DATE=date(2027, 1, 5)) == [
        "Hire date cannot be more than 90 days in the future."
    ]


def test_all_errors_are_reported_together():
    errors = errors_for(FIRST_NAME="", EMAIL="bad", SALARY=0.0)
    assert len(errors) == 3
