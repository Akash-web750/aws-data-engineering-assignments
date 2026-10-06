"""
test_filters.py - Unit tests for filters.py.

Checks every sidebar filter on its own and in combination, using the
four-employee sample table from conftest.py. Runs offline.
"""

from datetime import date

import pytest

from filters import FilterCriteria, apply_filters


def matching_ids(employees, **criteria):
    """Apply the given filters and return the matching employee IDs."""
    return list(apply_filters(employees, FilterCriteria(**criteria))["EMPLOYEE_ID"])


def test_default_criteria_return_every_employee(sample_employees):
    assert matching_ids(sample_employees) == [1001, 1002, 1003, 1004]


@pytest.mark.parametrize(
    "criteria, expected",
    [
        # Search matches name, e-mail and job title, ignoring case.
        ({"search": "vikram"}, [1002]),
        ({"search": "MANAGER"}, [1002, 1004]),
        ({"search": "employee1003@"}, [1003]),
        ({"search": "  asha rao  "}, [1001]),
        ({"search": "nobody"}, []),
        # Multi-select filters accept any of the chosen values.
        ({"departments": ["Engineering"]}, [1001, 1004]),
        ({"departments": ["Sales", "Finance"]}, [1002, 1003]),
        ({"employment_types": ["Contract", "Part-time"]}, [1002, 1004]),
        ({"locations": ["Pune"]}, [1001]),
        ({"genders": ["Male"]}, [1002, 1004]),
        # Skills: at least one chosen skill; an employee with no skills never matches.
        ({"skills": ["SQL"]}, [1001, 1003]),
        ({"skills": ["CRM", "Python"]}, [1001, 1002]),
        # Status and remote flags.
        ({"status": "Active"}, [1001, 1002, 1004]),
        ({"status": "Inactive"}, [1003]),
        ({"remote_only": True}, [1002, 1004]),
        # Numeric ranges include their end points.
        ({"min_salary": 900000.0}, [1001, 1003, 1004]),
        ({"max_salary": 900000.0}, [1001, 1002]),
        ({"min_salary": 700000.0, "max_salary": 2000000.0}, [1001, 1003]),
        ({"min_experience": 12.0}, [1003, 1004]),
        # Hire date range includes its end points.
        ({"hired_from": date(2023, 6, 1)}, [1002, 1004]),
        ({"hired_to": date(2020, 1, 15)}, [1001, 1003]),
        ({"hired_from": date(2019, 1, 1), "hired_to": date(2023, 12, 31)}, [1001, 1002]),
    ],
)
def test_single_filter(sample_employees, criteria, expected):
    assert matching_ids(sample_employees, **criteria) == expected


def test_filters_combine_with_and(sample_employees):
    # Engineering AND remote leaves only the remote engineer.
    assert matching_ids(sample_employees, departments=["Engineering"], remote_only=True) == [1004]
    # Adding a filter nobody satisfies empties the result.
    assert matching_ids(
        sample_employees, departments=["Engineering"], remote_only=True, status="Inactive",
    ) == []


def test_search_treats_special_characters_literally(sample_employees):
    # "." must match a real dot, not "any character".
    assert matching_ids(sample_employees, search="example.com") == [1001, 1002, 1003, 1004]
    assert matching_ids(sample_employees, search="example+com") == []


def test_filtering_an_empty_table_returns_an_empty_table(sample_employees):
    empty = sample_employees.iloc[0:0]
    assert apply_filters(empty, FilterCriteria(search="x", departments=["Sales"])).empty
