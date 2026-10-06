# Screenshots

**Status: none captured yet.** This folder holds the screenshots referenced from the project [README](../README.md). Capture them from the deployed app in Snowsight, save them here under the file names below, then update the status column in the main README.

## Capture list

| # | File name | What to show | How to get there |
|---|---|---|---|
| 1 | `01_dashboard.png` | Main employee dashboard: header, four metrics, paged list with Edit buttons | Open the app with no filters set |
| 2 | `02_filter_panel.png` | Sidebar filters in use, list narrowed | Choose Department = Sales and Status = Active |
| 3 | `03_add_employee_form.png` | Add Employee dialog, filled in, before saving | Click **➕ Add Employee** and complete the form |
| 4 | `04_edit_employee_form.png` | Edit Employee dialog pre-filled with an employee's values | Click **Edit** on any row |
| 5 | `05_employee_created.png` | Green "Added employee …" confirmation and the new total | Save the Add form |
| 6 | `06_employee_updated.png` | Green "Updated employee …" confirmation and the changed row | Save the Edit form |
| 7 | `07_snowflake_table.png` | The `EMPLOYEES` table in a Snowsight worksheet | Run section 4 of `sql/03_validate.sql` |
| 8 | `08_deployed_app.png` | The app listed and open under Projects → Streamlit, with the Snowsight frame visible | Snowsight → Projects → Streamlit → Employee Manager |

## Guidelines

- Use a browser window about 1600 px wide so the ten list columns fit without wrapping.
- PNG format, light theme.
- The sample data uses `@example.com` addresses and invented names, so nothing in the app needs hiding. Do crop or blur the Snowflake account identifier and your user name in the Snowsight frame (screenshots 7 and 8).
