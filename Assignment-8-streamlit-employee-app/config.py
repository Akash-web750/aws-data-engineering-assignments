"""
config.py - Central configuration for the Employee Manager app.

Holds the Snowflake object names, the allowed values for every dropdown-style
field, and the numeric limits used by validation. Keeping them in one module
means the form, the filter panel and the validation rules always agree.
"""

# ---------------------------------------------------------------------------
# Snowflake objects
# ---------------------------------------------------------------------------
# Database and schema that hold the EMPLOYEES table (see sql/01_create_objects.sql).
DATABASE = "AI_OPERATOR_DB"
SCHEMA = "EMPLOYEE_APP"

# Fully qualified table name, so queries work whatever the session's current schema is.
EMPLOYEES_TABLE = f"{DATABASE}.{SCHEMA}.EMPLOYEES"

# ---------------------------------------------------------------------------
# Allowed values for categorical fields
# ---------------------------------------------------------------------------
# Shown as radio buttons in the form.
GENDERS = ["Female", "Male", "Non-binary", "Prefer not to say"]
EMPLOYMENT_TYPES = ["Full-time", "Part-time", "Contract", "Intern"]

# Shown as select boxes in the form.
DEPARTMENTS = [
    "Engineering",
    "Data & Analytics",
    "Product",
    "Sales",
    "Marketing",
    "Finance",
    "Human Resources",
    "Customer Support",
]
WORK_LOCATIONS = ["Bengaluru", "Pune", "Mumbai", "Hyderabad", "Chennai", "Delhi NCR"]

# Shown as a multi-select in the form; stored in the SKILLS array column.
SKILLS = [
    "Python",
    "SQL",
    "Snowflake",
    "AWS",
    "Java",
    "JavaScript",
    "Data Modelling",
    "Machine Learning",
    "Power BI",
    "Excel",
    "Product Strategy",
    "Negotiation",
    "CRM",
    "SEO",
    "Content Writing",
    "Financial Analysis",
    "Recruitment",
    "Communication",
    "Project Management",
    "Customer Service",
]

# ---------------------------------------------------------------------------
# Validation limits
# ---------------------------------------------------------------------------
NAME_MAX_LENGTH = 50          # FIRST_NAME / LAST_NAME column size
EMAIL_MAX_LENGTH = 120        # EMAIL column size
JOB_TITLE_MAX_LENGTH = 80     # JOB_TITLE column size
NOTES_MAX_LENGTH = 1000       # NOTES column size
MAX_SALARY = 100_000_000.0    # Upper bound for the annual salary
MAX_EXPERIENCE_YEARS = 50.0   # Upper bound for total experience
MAX_SKILLS = 10               # Most skills one employee may have
MIN_AGE_AT_HIRE = 18          # Youngest allowed age on the hire date
MAX_FUTURE_HIRE_DAYS = 90     # How far ahead a hire date may be

# ---------------------------------------------------------------------------
# List display
# ---------------------------------------------------------------------------
PAGE_SIZE_OPTIONS = [10, 25, 50]   # Choices for "Rows per page"
