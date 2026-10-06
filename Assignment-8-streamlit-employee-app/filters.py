"""
filters.py - Filter criteria and filtering logic for the employee list.

The sidebar builds a FilterCriteria object from its widgets; apply_filters()
then narrows the employee DataFrame. The logic is plain pandas with no
Streamlit or Snowflake imports, so it can be unit tested offline.
"""

from dataclasses import dataclass, field
from datetime import date
from typing import List, Optional

import pandas as pd

# Values of the Status radio button in the filter panel.
STATUS_ALL = "All"
STATUS_ACTIVE = "Active"
STATUS_INACTIVE = "Inactive"
STATUS_OPTIONS = [STATUS_ALL, STATUS_ACTIVE, STATUS_INACTIVE]


@dataclass
class FilterCriteria:
    """One field per sidebar filter. The defaults mean 'no filter'."""

    search: str = ""                                        # Name, e-mail or job title contains this text
    departments: List[str] = field(default_factory=list)    # Any of these departments
    employment_types: List[str] = field(default_factory=list)
    locations: List[str] = field(default_factory=list)
    genders: List[str] = field(default_factory=list)
    skills: List[str] = field(default_factory=list)         # Employee has at least one of these skills
    status: str = STATUS_ALL                                # All / Active / Inactive
    remote_only: bool = False                               # Only employees who work remotely
    min_salary: Optional[float] = None
    max_salary: Optional[float] = None
    min_experience: Optional[float] = None
    hired_from: Optional[date] = None
    hired_to: Optional[date] = None


def apply_filters(employees, criteria):
    """
    Return the rows of `employees` that satisfy every active filter.

    Filters are combined with AND. A filter left at its default is skipped,
    so default criteria return the DataFrame unchanged.
    """
    # Start with every row selected, then switch rows off filter by filter.
    keep = pd.Series(True, index=employees.index)

    # Free-text search across the name, e-mail and job title.
    search = criteria.search.strip().lower()
    if search:
        searchable = (
            employees["FIRST_NAME"].fillna("") + " "
            + employees["LAST_NAME"].fillna("") + " "
            + employees["EMAIL"].fillna("") + " "
            + employees["JOB_TITLE"].fillna("")
        ).str.lower()
        # regex=False so characters such as "." or "+" are matched literally.
        keep &= searchable.str.contains(search, regex=False)

    # Multi-select filters: the row's value must be one of the chosen values.
    if criteria.departments:
        keep &= employees["DEPARTMENT"].isin(criteria.departments)
    if criteria.employment_types:
        keep &= employees["EMPLOYMENT_TYPE"].isin(criteria.employment_types)
    if criteria.locations:
        keep &= employees["WORK_LOCATION"].isin(criteria.locations)
    if criteria.genders:
        keep &= employees["GENDER"].isin(criteria.genders)

    # Skills is a list per row: keep the row if it shares any skill with the filter.
    if criteria.skills:
        wanted = set(criteria.skills)
        keep &= employees["SKILLS"].apply(lambda skills: bool(wanted.intersection(skills)))

    # Active / inactive status.
    if criteria.status == STATUS_ACTIVE:
        keep &= employees["IS_ACTIVE"].astype(bool)
    elif criteria.status == STATUS_INACTIVE:
        keep &= ~employees["IS_ACTIVE"].astype(bool)

    # Remote workers only.
    if criteria.remote_only:
        keep &= employees["IS_REMOTE"].astype(bool)

    # Numeric ranges; None means that side of the range is open.
    if criteria.min_salary is not None:
        keep &= employees["SALARY"] >= criteria.min_salary
    if criteria.max_salary is not None:
        keep &= employees["SALARY"] <= criteria.max_salary
    if criteria.min_experience is not None:
        keep &= employees["EXPERIENCE_YEARS"] >= criteria.min_experience

    # Hire date range; None means that side of the range is open.
    if criteria.hired_from is not None:
        keep &= employees["HIRE_DATE"].apply(lambda hired: hired >= criteria.hired_from)
    if criteria.hired_to is not None:
        keep &= employees["HIRE_DATE"].apply(lambda hired: hired <= criteria.hired_to)

    return employees[keep]
