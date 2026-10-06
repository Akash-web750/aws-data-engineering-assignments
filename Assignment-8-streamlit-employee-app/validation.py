"""
validation.py - Cleaning and validation of employee form input.

This module has no Streamlit or Snowflake imports, so every rule can be unit
tested offline. The app calls clean_employee() and then validate_employee()
before it writes anything to the EMPLOYEES table.
"""

import re
from datetime import date, timedelta

import config

# Letters (any language), spaces, dots, apostrophes and hyphens: "Anne-Marie", "O'Brien".
_NAME_PATTERN = re.compile(r"^[^\W\d_]+(?:[ .'\-][^\W\d_]+)*\.?$")

# A deliberately simple e-mail check: something@domain.tld with no spaces.
_EMAIL_PATTERN = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+$")

# Phone numbers may start with "+" and contain digits, spaces and hyphens.
_PHONE_PATTERN = re.compile(r"^\+?[0-9][0-9 \-]*$")


def _text(value):
    """Return a trimmed string; None and other blanks become an empty string."""
    return str(value).strip() if value is not None else ""


def clean_employee(raw):
    """
    Normalise raw form values into the shape that is stored in the table.

    - Text is trimmed and inner runs of spaces in names are collapsed.
    - E-mail is lower-cased so the uniqueness check is case-insensitive.
    - Optional text (phone, notes) becomes None when left empty, so it is
      stored as NULL instead of an empty string.
    - Skills are de-duplicated while keeping the order the user chose.
    """
    skills = []
    for skill in raw.get("SKILLS") or []:
        if skill not in skills:
            skills.append(skill)

    return {
        "FIRST_NAME": " ".join(_text(raw.get("FIRST_NAME")).split()),
        "LAST_NAME": " ".join(_text(raw.get("LAST_NAME")).split()),
        "EMAIL": _text(raw.get("EMAIL")).lower(),
        "PHONE": _text(raw.get("PHONE")) or None,
        "GENDER": raw.get("GENDER"),
        "DATE_OF_BIRTH": raw.get("DATE_OF_BIRTH"),
        "DEPARTMENT": raw.get("DEPARTMENT"),
        "JOB_TITLE": " ".join(_text(raw.get("JOB_TITLE")).split()),
        "EMPLOYMENT_TYPE": raw.get("EMPLOYMENT_TYPE"),
        "WORK_LOCATION": raw.get("WORK_LOCATION"),
        "HIRE_DATE": raw.get("HIRE_DATE"),
        "SALARY": raw.get("SALARY"),
        "EXPERIENCE_YEARS": raw.get("EXPERIENCE_YEARS"),
        "SKILLS": skills,
        "IS_ACTIVE": bool(raw.get("IS_ACTIVE")),
        "IS_REMOTE": bool(raw.get("IS_REMOTE")),
        "NOTES": _text(raw.get("NOTES")) or None,
    }


def _years_between(start, end):
    """Whole years from start to end (the usual 'age' calculation)."""
    years = end.year - start.year
    # Subtract one year if the anniversary has not been reached yet.
    if (end.month, end.day) < (start.month, start.day):
        years -= 1
    return years


def _validate_name(label, value, errors):
    """Apply the shared rules for first and last names."""
    if not value:
        errors.append(f"{label} is required.")
    elif len(value) > config.NAME_MAX_LENGTH:
        errors.append(f"{label} must be {config.NAME_MAX_LENGTH} characters or fewer.")
    elif not _NAME_PATTERN.match(value):
        errors.append(f"{label} may contain only letters, spaces, dots, apostrophes and hyphens.")


def validate_employee(employee, today=None):
    """
    Check a cleaned employee dictionary against every business rule.

    Returns a list of error messages; an empty list means the data is valid.
    `today` can be passed in so tests do not depend on the real date.
    E-mail uniqueness is not checked here because it needs a database query;
    the app checks it separately.
    """
    today = today or date.today()
    errors = []

    # --- Names and job title -------------------------------------------------
    _validate_name("First name", employee["FIRST_NAME"], errors)
    _validate_name("Last name", employee["LAST_NAME"], errors)

    if not employee["JOB_TITLE"]:
        errors.append("Job title is required.")
    elif len(employee["JOB_TITLE"]) > config.JOB_TITLE_MAX_LENGTH:
        errors.append(f"Job title must be {config.JOB_TITLE_MAX_LENGTH} characters or fewer.")

    # --- Contact details -----------------------------------------------------
    email = employee["EMAIL"]
    if not email:
        errors.append("Email is required.")
    elif len(email) > config.EMAIL_MAX_LENGTH or not _EMAIL_PATTERN.match(email):
        errors.append("Enter a valid email address.")

    phone = employee["PHONE"]
    if phone:
        digit_count = sum(character.isdigit() for character in phone)
        if not _PHONE_PATTERN.match(phone) or not 7 <= digit_count <= 15:
            errors.append("Enter a valid phone number (7 to 15 digits; +, spaces and hyphens are allowed).")

    # --- Choice fields: a value must be selected -----------------------------
    if not employee["GENDER"]:
        errors.append("Select a gender.")
    if not employee["DEPARTMENT"]:
        errors.append("Select a department.")
    if not employee["EMPLOYMENT_TYPE"]:
        errors.append("Select an employment type.")
    if not employee["WORK_LOCATION"]:
        errors.append("Select a work location.")

    # --- Dates ---------------------------------------------------------------
    birth_date = employee["DATE_OF_BIRTH"]
    hire_date = employee["HIRE_DATE"]
    if not birth_date:
        errors.append("Date of birth is required.")
    if not hire_date:
        errors.append("Hire date is required.")
    if hire_date and hire_date > today + timedelta(days=config.MAX_FUTURE_HIRE_DAYS):
        errors.append(f"Hire date cannot be more than {config.MAX_FUTURE_HIRE_DAYS} days in the future.")
    if birth_date and hire_date and _years_between(birth_date, hire_date) < config.MIN_AGE_AT_HIRE:
        errors.append(f"Employee must be at least {config.MIN_AGE_AT_HIRE} years old on the hire date.")

    # --- Numbers -------------------------------------------------------------
    salary = employee["SALARY"]
    if salary is None or not 0 < salary <= config.MAX_SALARY:
        errors.append(f"Salary must be greater than 0 and at most {config.MAX_SALARY:,.0f}.")

    experience = employee["EXPERIENCE_YEARS"]
    if experience is None or not 0 <= experience <= config.MAX_EXPERIENCE_YEARS:
        errors.append(f"Experience must be between 0 and {config.MAX_EXPERIENCE_YEARS:.0f} years.")

    # --- Skills and notes ----------------------------------------------------
    if len(employee["SKILLS"]) > config.MAX_SKILLS:
        errors.append(f"Select at most {config.MAX_SKILLS} skills.")

    if employee["NOTES"] and len(employee["NOTES"]) > config.NOTES_MAX_LENGTH:
        errors.append(f"Notes must be {config.NOTES_MAX_LENGTH} characters or fewer.")

    return errors
