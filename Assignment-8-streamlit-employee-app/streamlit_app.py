"""
streamlit_app.py - Employee Manager (Streamlit in Snowflake).

Page layout:
  * Left sidebar : filter panel built from the employee attributes.
  * Header       : title, Refresh button and the "Add Employee" button.
  * Body         : summary metrics and a paged employee list with an Edit
                   button on every row.
  * Dialog       : one shared Add/Edit form whose widgets match each column's
                   data type.

Employee data is read from Snowflake on every script run and is never cached,
so the list always shows the latest rows after an insert or update.
"""

from datetime import date

import streamlit as st

import config
import employee_repository as repo
import filters
import validation

# "wide" uses the full browser width, which the multi-column list needs.
st.set_page_config(layout="wide")

# Relative widths and headings of the employee list columns.
LIST_COLUMN_WIDTHS = [0.7, 2.6, 1.7, 2.0, 1.2, 1.5, 1.2, 1.3, 1.0, 0.9]
LIST_HEADINGS = [
    "ID", "Employee", "Department", "Job title", "Type",
    "Location", "Hire date", "Salary (INR)", "Status", "Action",
]

# Session-state keys of the sidebar filter widgets; "Reset filters" clears them all.
FILTER_KEYS = [
    "flt_search", "flt_departments", "flt_types", "flt_locations", "flt_genders",
    "flt_skills", "flt_status", "flt_remote", "flt_min_salary", "flt_max_salary",
    "flt_min_experience", "flt_hired_from", "flt_hired_to",
]

# Earliest dates offered by the date pickers.
EARLIEST_BIRTH_DATE = date(1940, 1, 1)
EARLIEST_HIRE_DATE = date(1980, 1, 1)


# ---------------------------------------------------------------------------
# Data access helpers
# ---------------------------------------------------------------------------
@st.cache_resource
def get_session():
    """Create the Snowpark session once and reuse it on every rerun."""
    return repo.create_session()


def with_current_value(options, current):
    """
    Return `options`, adding `current` if it is missing.

    An employee edited outside the app may hold a value that is not in the
    configured list; adding it keeps the form from silently changing it.
    """
    if current and current not in options:
        return options + [current]
    return options


def options_including_data(base_options, column):
    """Return the configured options plus any other values present in the data."""
    extra = sorted(set(column.dropna()) - set(base_options))
    return base_options + extra


# ---------------------------------------------------------------------------
# Add / Edit form
# ---------------------------------------------------------------------------
def employee_form(employee=None):
    """
    Render the shared Add/Edit form and save it when submitted.

    `employee` is None when adding. When editing it is a dictionary of the
    employee's current values, which pre-fill the widgets.
    """
    is_edit = employee is not None
    current = employee or {}
    # A different key prefix per employee keeps widget state from leaking
    # between the Add form and the Edit forms of different employees.
    prefix = f"emp_{current['EMPLOYEE_ID']}" if is_edit else "emp_new"
    today = date.today()

    with st.form(key=f"{prefix}_form"):
        # --- Personal details ------------------------------------------------
        st.subheader("Personal details")
        left, right = st.columns(2)
        # Text inputs for short free text.
        first_name = left.text_input(
            "First name *", value=current.get("FIRST_NAME", ""),
            max_chars=config.NAME_MAX_LENGTH, key=f"{prefix}_first_name",
        )
        last_name = right.text_input(
            "Last name *", value=current.get("LAST_NAME", ""),
            max_chars=config.NAME_MAX_LENGTH, key=f"{prefix}_last_name",
        )
        email = left.text_input(
            "Email *", value=current.get("EMAIL", ""),
            max_chars=config.EMAIL_MAX_LENGTH, key=f"{prefix}_email",
        )
        phone = right.text_input(
            "Phone", value=current.get("PHONE") or "", max_chars=20,
            placeholder="+91 98765 43210", key=f"{prefix}_phone",
        )
        # Date input for a DATE column. No default when adding, so it must be chosen.
        date_of_birth = left.date_input(
            "Date of birth *", value=current.get("DATE_OF_BIRTH"),
            min_value=EARLIEST_BIRTH_DATE, max_value=today, key=f"{prefix}_date_of_birth",
        )
        # Radio buttons for a short list of exclusive choices.
        gender_options = with_current_value(config.GENDERS, current.get("GENDER"))
        gender = right.radio(
            "Gender *", gender_options,
            index=gender_options.index(current["GENDER"]) if is_edit else None,
            horizontal=True, key=f"{prefix}_gender",
        )

        # --- Job details -----------------------------------------------------
        st.subheader("Job details")
        left, right = st.columns(2)
        # Select boxes for longer lists of exclusive choices.
        department_options = with_current_value(config.DEPARTMENTS, current.get("DEPARTMENT"))
        department = left.selectbox(
            "Department *", department_options,
            index=department_options.index(current["DEPARTMENT"]) if is_edit else None,
            placeholder="Choose a department", key=f"{prefix}_department",
        )
        job_title = right.text_input(
            "Job title *", value=current.get("JOB_TITLE", ""),
            max_chars=config.JOB_TITLE_MAX_LENGTH, key=f"{prefix}_job_title",
        )
        location_options = with_current_value(config.WORK_LOCATIONS, current.get("WORK_LOCATION"))
        work_location = left.selectbox(
            "Work location *", location_options,
            index=location_options.index(current["WORK_LOCATION"]) if is_edit else None,
            placeholder="Choose a location", key=f"{prefix}_work_location",
        )
        hire_date = right.date_input(
            "Hire date *", value=current.get("HIRE_DATE", today),
            min_value=EARLIEST_HIRE_DATE, key=f"{prefix}_hire_date",
        )
        type_options = with_current_value(config.EMPLOYMENT_TYPES, current.get("EMPLOYMENT_TYPE"))
        employment_type = st.radio(
            "Employment type *", type_options,
            index=type_options.index(current.get("EMPLOYMENT_TYPE", config.EMPLOYMENT_TYPES[0])),
            horizontal=True, key=f"{prefix}_employment_type",
        )
        left, right = st.columns(2)
        # Number inputs for numeric columns.
        salary = left.number_input(
            "Annual salary (INR) *", min_value=0.0, max_value=config.MAX_SALARY,
            value=float(current.get("SALARY", 0.0)), step=10000.0, format="%.2f",
            key=f"{prefix}_salary",
        )
        experience_years = right.number_input(
            "Experience (years) *", min_value=0.0, max_value=config.MAX_EXPERIENCE_YEARS,
            value=float(current.get("EXPERIENCE_YEARS", 0.0)), step=0.5, format="%.1f",
            key=f"{prefix}_experience_years",
        )
        # Multi-select for the SKILLS array column.
        current_skills = list(current.get("SKILLS", []))
        skill_options = config.SKILLS + [skill for skill in current_skills if skill not in config.SKILLS]
        skills = st.multiselect(
            "Skills", skill_options, default=current_skills,
            max_selections=config.MAX_SKILLS, key=f"{prefix}_skills",
        )
        left, right = st.columns(2)
        # Checkboxes for BOOLEAN columns. A new employee is active by default.
        is_active = left.checkbox(
            "Active employee", value=bool(current.get("IS_ACTIVE", True)), key=f"{prefix}_is_active",
        )
        is_remote = right.checkbox(
            "Works remotely", value=bool(current.get("IS_REMOTE", False)), key=f"{prefix}_is_remote",
        )
        # Text area for long free text.
        notes = st.text_area(
            "Notes", value=current.get("NOTES") or "",
            max_chars=config.NOTES_MAX_LENGTH, key=f"{prefix}_notes",
        )

        st.caption("Fields marked * are required.")
        save_column, cancel_column, _ = st.columns([1.4, 1, 4])
        submitted = save_column.form_submit_button(
            "Save changes" if is_edit else "Add employee", type="primary",
        )
        cancelled = cancel_column.form_submit_button("Cancel")

    if cancelled:
        # A full rerun closes the dialog without saving.
        st.rerun()

    if not submitted:
        return

    # Clean the raw widget values, then apply every validation rule.
    cleaned = validation.clean_employee({
        "FIRST_NAME": first_name,
        "LAST_NAME": last_name,
        "EMAIL": email,
        "PHONE": phone,
        "GENDER": gender,
        "DATE_OF_BIRTH": date_of_birth,
        "DEPARTMENT": department,
        "JOB_TITLE": job_title,
        "EMPLOYMENT_TYPE": employment_type,
        "WORK_LOCATION": work_location,
        "HIRE_DATE": hire_date,
        "SALARY": salary,
        "EXPERIENCE_YEARS": experience_years,
        "SKILLS": skills,
        "IS_ACTIVE": is_active,
        "IS_REMOTE": is_remote,
        "NOTES": notes,
    })
    errors = validation.validate_employee(cleaned, today=today)

    session = get_session()
    employee_id = current.get("EMPLOYEE_ID")
    try:
        # The uniqueness check needs the database, so it runs only for a valid e-mail.
        if not errors and repo.email_exists(session, cleaned["EMAIL"], exclude_employee_id=employee_id):
            errors.append("Another employee already uses this email.")

        if errors:
            # Show every problem at once and keep the dialog open for correction.
            st.error("Please fix the following:\n\n" + "\n".join(f"- {error}" for error in errors))
            return

        full_name = f"{cleaned['FIRST_NAME']} {cleaned['LAST_NAME']}"
        if is_edit:
            updated_rows = repo.update_employee(session, employee_id, cleaned)
            if updated_rows == 0:
                st.error("This employee no longer exists. Close the form and refresh the list.")
                return
            message = f"Updated employee {employee_id}: {full_name}."
        else:
            new_id = repo.insert_employee(session, cleaned)
            message = f"Added employee {new_id}: {full_name}."
    except Exception as error:  # Any Snowflake failure is shown instead of crashing the app.
        st.error(f"The employee could not be saved: {error}")
        return

    # Keep the confirmation for the next run, then rerun the whole app: this
    # closes the dialog and reloads the list from Snowflake.
    st.session_state["flash_message"] = message
    st.rerun()


@st.dialog("Add employee", width="large")
def add_employee_dialog():
    """Modal dialog holding the empty form."""
    employee_form()


@st.dialog("Edit employee", width="large")
def edit_employee_dialog(employee):
    """Modal dialog holding the form pre-filled with one employee."""
    st.caption(f"Employee ID {employee['EMPLOYEE_ID']}")
    employee_form(employee)


# ---------------------------------------------------------------------------
# Filter panel (left sidebar)
# ---------------------------------------------------------------------------
def reset_filters():
    """Button callback: drop every filter widget's state so it returns to its default."""
    for key in FILTER_KEYS:
        st.session_state.pop(key, None)


def render_filter_panel(employees):
    """Draw the sidebar filters and return the chosen values as FilterCriteria."""
    today = date.today()
    all_skills = sorted({skill for skills in employees["SKILLS"] for skill in skills})

    with st.sidebar:
        st.header("Filters")
        search = st.text_input(
            "Search", placeholder="Name, email or job title", key="flt_search",
        )
        departments = st.multiselect(
            "Department", options_including_data(config.DEPARTMENTS, employees["DEPARTMENT"]),
            key="flt_departments",
        )
        employment_types = st.multiselect(
            "Employment type",
            options_including_data(config.EMPLOYMENT_TYPES, employees["EMPLOYMENT_TYPE"]),
            key="flt_types",
        )
        locations = st.multiselect(
            "Work location",
            options_including_data(config.WORK_LOCATIONS, employees["WORK_LOCATION"]),
            key="flt_locations",
        )
        genders = st.multiselect(
            "Gender", options_including_data(config.GENDERS, employees["GENDER"]),
            key="flt_genders",
        )
        skills = st.multiselect(
            "Skills (any of)",
            config.SKILLS + [skill for skill in all_skills if skill not in config.SKILLS],
            key="flt_skills",
        )
        status = st.radio("Status", filters.STATUS_OPTIONS, horizontal=True, key="flt_status")
        remote_only = st.checkbox("Remote only", key="flt_remote")

        # Empty number and date inputs mean "no limit", so a newly added
        # employee is never hidden by a stale range.
        st.subheader("Salary (INR)")
        left, right = st.columns(2)
        min_salary = left.number_input(
            "Minimum", min_value=0.0, value=None, step=50000.0, format="%.0f",
            placeholder="Any", key="flt_min_salary",
        )
        max_salary = right.number_input(
            "Maximum", min_value=0.0, value=None, step=50000.0, format="%.0f",
            placeholder="Any", key="flt_max_salary",
        )
        min_experience = st.number_input(
            "Minimum experience (years)", min_value=0.0, max_value=config.MAX_EXPERIENCE_YEARS,
            value=None, step=1.0, format="%.1f", placeholder="Any", key="flt_min_experience",
        )

        st.subheader("Hire date")
        left, right = st.columns(2)
        hired_from = left.date_input(
            "From", value=None, min_value=EARLIEST_HIRE_DATE,
            max_value=date(today.year + 1, 12, 31), key="flt_hired_from",
        )
        hired_to = right.date_input(
            "To", value=None, min_value=EARLIEST_HIRE_DATE,
            max_value=date(today.year + 1, 12, 31), key="flt_hired_to",
        )

        st.button("Reset filters", on_click=reset_filters, use_container_width=True)

    return filters.FilterCriteria(
        search=search,
        departments=departments,
        employment_types=employment_types,
        locations=locations,
        genders=genders,
        skills=skills,
        status=status,
        remote_only=remote_only,
        min_salary=min_salary,
        max_salary=max_salary,
        min_experience=min_experience,
        hired_from=hired_from,
        hired_to=hired_to,
    )


# ---------------------------------------------------------------------------
# Page sections
# ---------------------------------------------------------------------------
def render_header():
    """Draw the title row with the Refresh and Add Employee buttons."""
    title_column, refresh_column, add_column = st.columns([6, 1, 1.6], vertical_alignment="bottom")
    title_column.title("Employee Manager")
    title_column.caption("View, filter, add and edit the employees stored in Snowflake.")

    # Clicking any button reruns the script, which already reloads the data,
    # so Refresh needs no handler of its own.
    refresh_column.button("Refresh", use_container_width=True)

    if add_column.button("➕ Add Employee", type="primary", use_container_width=True):
        add_employee_dialog()


def render_metrics(all_employees, shown_employees):
    """Draw four summary numbers for the filtered employees."""
    total, shown, active, average = st.columns(4)
    total.metric("Employees in table", len(all_employees))
    shown.metric("Matching filters", len(shown_employees))
    active.metric("Active (matching)", int(shown_employees["IS_ACTIVE"].sum()))
    average_salary = shown_employees["SALARY"].mean() if len(shown_employees) else 0
    average.metric("Average salary (matching)", f"₹{average_salary:,.0f}")


def render_pagination(row_count):
    """Draw the paging controls and return (first_row, last_row) of the current page."""
    info_column, size_column, page_column = st.columns([5, 1.2, 1.2], vertical_alignment="bottom")
    page_size = size_column.selectbox("Rows per page", config.PAGE_SIZE_OPTIONS, key="page_size")

    # Ceiling division; at least one page so the page input always has a valid range.
    page_count = max(1, -(-row_count // page_size))
    # Filters may have shrunk the list: pull a stale page number back into range.
    if st.session_state.get("page_number", 1) > page_count:
        st.session_state["page_number"] = page_count
    page_number = page_column.number_input(
        f"Page (of {page_count})", min_value=1, max_value=page_count, step=1, key="page_number",
    )

    first_row = (page_number - 1) * page_size
    last_row = min(first_row + page_size, row_count)
    info_column.markdown(f"Showing **{first_row + 1 if row_count else 0}–{last_row}** of **{row_count}** employees")
    return first_row, last_row


def render_employee_list(employees):
    """Draw one bordered row per employee, each with its own Edit button."""
    # Heading row.
    for column, heading in zip(st.columns(LIST_COLUMN_WIDTHS), LIST_HEADINGS):
        column.markdown(f"**{heading}**")

    for employee in employees.to_dict("records"):
        with st.container(border=True):
            columns = st.columns(LIST_COLUMN_WIDTHS, vertical_alignment="center")
            columns[0].write(str(employee["EMPLOYEE_ID"]))
            columns[1].markdown(f"**{employee['FIRST_NAME']} {employee['LAST_NAME']}**")
            columns[1].caption(employee["EMAIL"])
            columns[2].write(employee["DEPARTMENT"])
            columns[3].write(employee["JOB_TITLE"])
            columns[4].write(employee["EMPLOYMENT_TYPE"])
            columns[5].write(employee["WORK_LOCATION"] + (" · Remote" if employee["IS_REMOTE"] else ""))
            columns[6].write(employee["HIRE_DATE"].strftime("%d %b %Y"))
            columns[7].write(f"₹{employee['SALARY']:,.0f}")
            columns[8].markdown(":green[Active]" if employee["IS_ACTIVE"] else ":gray[Inactive]")
            # The key makes each row's button unique; clicking it opens that
            # employee in the Edit dialog.
            if columns[9].button("Edit", key=f"edit_{employee['EMPLOYEE_ID']}", use_container_width=True):
                edit_employee_dialog(employee)


def render_full_table(employees):
    """Draw every column of the filtered employees in a collapsible table."""
    with st.expander("All columns for the matching employees"):
        table = employees.copy()
        # Show the skills list as readable text.
        table["SKILLS"] = table["SKILLS"].apply(", ".join)
        st.dataframe(table, hide_index=True, use_container_width=True)


# ---------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------
def main():
    """Build the page from top to bottom."""
    # Show the confirmation left by the previous run's save, once.
    if "flash_message" in st.session_state:
        st.success(st.session_state.pop("flash_message"))

    # Always read the current table contents; nothing here is cached.
    try:
        employees = repo.fetch_employees(get_session())
    except Exception as error:
        st.error(f"The employee data could not be loaded: {error}")
        st.stop()

    render_header()
    criteria = render_filter_panel(employees)
    matching = filters.apply_filters(employees, criteria)
    render_metrics(employees, matching)

    if matching.empty:
        st.info("No employees match the current filters.")
        return

    first_row, last_row = render_pagination(len(matching))
    render_employee_list(matching.iloc[first_row:last_row])
    render_full_table(matching)


main()
