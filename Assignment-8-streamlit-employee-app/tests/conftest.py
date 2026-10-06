"""
conftest.py - Shared pytest setup for the Employee Manager tests.

Adds the project folder to sys.path so the tests can import the app modules
(config, validation, filters, employee_repository), and provides a small
sample employee table used by several test files.
"""

import sys
from datetime import date
from pathlib import Path

import pandas as pd
import pytest

# The app modules live one level above this tests folder.
PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR))


def make_employee(employee_id, **overrides):
    """Return one valid employee row; keyword arguments replace individual values."""
    employee = {
        "EMPLOYEE_ID": employee_id,
        "FIRST_NAME": "Asha",
        "LAST_NAME": "Rao",
        "EMAIL": f"employee{employee_id}@example.com",
        "PHONE": "+91 98765 43210",
        "GENDER": "Female",
        "DATE_OF_BIRTH": date(1990, 5, 20),
        "DEPARTMENT": "Engineering",
        "JOB_TITLE": "Software Engineer",
        "EMPLOYMENT_TYPE": "Full-time",
        "WORK_LOCATION": "Pune",
        "HIRE_DATE": date(2020, 1, 15),
        "SALARY": 900000.0,
        "EXPERIENCE_YEARS": 6.0,
        "SKILLS": ["Python", "SQL"],
        "IS_ACTIVE": True,
        "IS_REMOTE": False,
        "NOTES": None,
    }
    employee.update(overrides)
    return employee


@pytest.fixture
def sample_employees():
    """Four employees that differ in every attribute the filters use."""
    return pd.DataFrame([
        make_employee(1001),
        make_employee(
            1002, FIRST_NAME="Vikram", LAST_NAME="Singh", GENDER="Male",
            DEPARTMENT="Sales", JOB_TITLE="Account Manager", EMPLOYMENT_TYPE="Contract",
            WORK_LOCATION="Mumbai", HIRE_DATE=date(2023, 6, 1), SALARY=600000.0,
            EXPERIENCE_YEARS=3.0, SKILLS=["CRM", "Negotiation"], IS_REMOTE=True,
        ),
        make_employee(
            1003, FIRST_NAME="Meera", LAST_NAME="Nair", DEPARTMENT="Finance",
            JOB_TITLE="Financial Analyst", WORK_LOCATION="Chennai",
            HIRE_DATE=date(2018, 3, 10), SALARY=1500000.0, EXPERIENCE_YEARS=12.0,
            SKILLS=["Excel", "SQL"], IS_ACTIVE=False,
        ),
        make_employee(
            1004, FIRST_NAME="Karan", LAST_NAME="Mehta", GENDER="Male",
            DEPARTMENT="Engineering", JOB_TITLE="Engineering Manager",
            EMPLOYMENT_TYPE="Part-time", WORK_LOCATION="Bengaluru",
            HIRE_DATE=date(2025, 11, 3), SALARY=2400000.0, EXPERIENCE_YEARS=15.0,
            SKILLS=[], IS_REMOTE=True,
        ),
    ])
