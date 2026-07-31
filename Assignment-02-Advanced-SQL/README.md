# Assignment 02 - Advanced SQL Transformations using PostgreSQL

## Objective

This project demonstrates advanced SQL transformations using PostgreSQL by solving real-world analytical business problems.

The assignment focuses on writing optimized SQL queries using modern SQL features such as Window Functions, Common Table Expressions (CTEs), Aggregate Functions, and Complex JOINs without using stored procedures, cursors, or loops.

The project simulates a retail sales database and generates business insights from customer purchases, product sales, and category-wise performance.

---

# Project Overview

This project is designed to strengthen SQL analytical skills through practical business scenarios.

A relational database containing Customers, Products, Categories, and Sales data is created in PostgreSQL. Various SQL queries are written to analyze sales performance, identify top-selling products, rank customers, calculate moving averages, and generate summary reports.

The project demonstrates how SQL can be used as a powerful analytical tool for reporting and business intelligence.

---

# Solution Architecture

```text
                    Categories
                         │
                         │
                         ▼
                     Products
                         │
                         │
                         ▼
        Customers ───► Sales ◄──── Products
                         │
                         │
                         ▼
                SQL Analytical Queries
                         │
                         ▼
                 Business Insights &
                 Summary Reports
```

---

# Database Schema

The project contains four relational tables.

| Table | Description |
|--------|-------------|
| Categories | Stores product category information |
| Products | Stores product details and category mapping |
| Customers | Stores customer information |
| Sales | Stores customer purchase transactions |

---

# Table Relationships

```text
Categories
     │
     │ (1 : Many)
     ▼
Products
     │
     │ (1 : Many)
     ▼
Sales
     ▲
     │ (Many : 1)
Customers
```

---

# Database Overview

The database represents a simple retail sales management system.

Each product belongs to one category.

Each customer can purchase multiple products.

Each sale represents a transaction between a customer and a product.

The SQL queries analyze these relationships to generate meaningful business reports.

---

# Dataset Information

| Table | Number of Records |
|--------|------------------:|
| Categories | 5 |
| Products | 20 |
| Customers | 30 |
| Sales | 100 |

---

# Project Documentation

Additional documentation is available inside the **doc/** folder.

| Document | Description |
|----------|-------------|
| Assignment_Description.md | Assignment objectives and requirements |
| Database_Schema.md | Database design and table relationships |
| Dataset.md | Dataset description |
| Output_Summary.md | Summary of SQL query outputs |
| ER_Diagram.png | Database Entity Relationship (ER) Diagram |

---

# Project Structure

```text
Assignment-02-Advanced-SQL/
│
├── doc/
│   ├── Assignment_Description.md
│   ├── Database_Schema.md
│   ├── Dataset.md
│   ├── Output_Summary.md
│   └── ER_Diagram.png
│
├── screenshot/
│   ├── 02_categories_data.png
│   ├── 03_products_data.png
│   ├── 04_customers_data.png
│   ├── 05_sales_data.png
│   ├── 06_query1_top3_products.png
│   ├── 07_query2_lag_function.png
│   ├── 08_query3_lead_function.png
│   ├── 09_query4_rank_function.png
│   ├── 10_query5_partition_rank.png
│   ├── 11_moving_average.png
│   ├── 12_row_number.png
│   ├── 13_dense_rank.png
│   ├── 14_complex_join.png
│   ├── 15_customer_sales_summary.png
│   ├── 16_category_sales_summary.png
│   ├── 17_customer_category_report.png
│   └── 18_best_customer_city.png
│
├── sql/
│   ├── 01_create_tables.sql
│   ├── 02_insert_data.sql
│   ├── 03_question1_window_functions.sql
│   ├── 04_question2_moving_average.sql
│   └── 05_question3_complex_join.sql
│
└── README.md
```

---

# Project Workflow

### Step 1 – Create Database

Execute the SQL script to create all database tables.

↓

### Step 2 – Insert Sample Data

Populate the tables with sample records.

↓

### Step 3 – Execute Analytical Queries

Run advanced SQL queries using Window Functions, CTEs, Aggregate Functions, and Complex JOINs.

↓

### Step 4 – Analyze Results

Review the generated reports and business insights.

↓

### Step 5 – Validate Output

Compare query outputs with the expected analytical results and summaries.

---


# SQL Concepts Covered

This assignment demonstrates a wide range of SQL concepts used in real-world Data Engineering and Business Intelligence projects.

### Basic SQL

- SELECT
- WHERE
- ORDER BY
- GROUP BY
- HAVING
- Aggregate Functions

---

### Joins

- INNER JOIN
- LEFT JOIN
- Multiple Table JOINs

---

### Window Functions

- RANK()
- DENSE_RANK()
- ROW_NUMBER()
- LEAD()
- LAG()

---

### Advanced SQL

- Common Table Expressions (CTE)
- PARTITION BY
- Moving Average
- Analytical Queries
- Business Reporting

---

# SQL Files

The project is divided into multiple SQL scripts for better organization.

| SQL File | Description |
|----------|-------------|
| 01_create_tables.sql | Creates all database tables |
| 02_insert_data.sql | Inserts sample data into all tables |
| 03_question1_window_functions.sql | Window Functions, LEAD(), LAG(), RANK() |
| 04_question2_moving_average.sql | Moving Average and Product Ranking |
| 05_question3_complex_join.sql | Complex JOINs and Business Reports |

---

# Assignment Tasks

The assignment contains three analytical SQL tasks.

---

## Question 1 – Window Functions

### Objective

Analyze sales trends using advanced Window Functions.

### SQL Concepts Used

- CTE
- RANK()
- LEAD()
- LAG()

### Business Use Case

- Compare current and previous sales.
- Identify future sales values.
- Rank products based on sales performance.

---

## Question 2 – Moving Average & Product Ranking

### Objective

Analyze product sales using moving averages and ranking.

### SQL Concepts Used

- Moving Average
- PARTITION BY
- Window Functions

### Business Use Case

- Identify sales trends.
- Compare products within each category.
- Rank top-performing products.

---

## Question 3 – Complex JOIN & Business Reports

### Objective

Generate business reports by combining multiple relational tables.

### SQL Concepts Used

- INNER JOIN
- LEFT JOIN
- GROUP BY
- Aggregate Functions

### Business Use Case

Generate reports such as:

- Customer Sales Summary
- Category Sales Summary
- Customer Category Report
- Best Customer by City

---

# Technologies Used

## Database

- PostgreSQL

---

## Development Tool

- pgAdmin 4

---

## Programming Language

- SQL

---

## Version Control

- Git
- GitHub

---

# Requirements

Before running this project, ensure the following software is installed.

- PostgreSQL
- pgAdmin 4
- Git (Optional)

---

# How to Run

## Step 1

Clone the repository.

```bash
git clone https://github.com/Akash-web750/aws-data-engineering-assignments.git
```

---

## Step 2

Open pgAdmin 4 and connect to your PostgreSQL server.

---

## Step 3

Execute the following SQL files in order.

```text
01_create_tables.sql

↓

02_insert_data.sql

↓

03_question1_window_functions.sql

↓

04_question2_moving_average.sql

↓

05_question3_complex_join.sql
```

---

## Step 4

Verify the generated query outputs.

---

## Step 5

Compare the outputs with the screenshots available inside the **screenshot/** folder.

---

# Testing

The project was tested by executing all SQL scripts sequentially.

### Test Case 1

Create database tables.

**Expected Result**

- All tables are created successfully.

---

### Test Case 2

Insert sample records.

**Expected Result**

- Sample data is inserted successfully.

---

### Test Case 3

Execute analytical SQL queries.

**Expected Result**

- All queries execute successfully.
- No SQL syntax errors.
- Expected analytical reports are generated.

---



# Skills Demonstrated

This project demonstrates practical SQL and Data Engineering skills commonly used in real-world analytical and reporting projects.

- SQL Query Writing
- PostgreSQL Database Management
- Relational Database Design
- Window Functions
- Common Table Expressions (CTEs)
- Aggregate Functions
- Complex JOIN Operations
- Data Analysis
- Business Intelligence Reporting
- Query Optimization
- Analytical SQL
- Data Transformation
- Problem Solving
- Git Version Control
- GitHub Repository Management
- Database Query Optimization
- Business Data Analysis
---

# Learning Outcomes

This project helped in understanding:

- Relational Database Design
- SQL Query Optimization
- Window Functions
- Common Table Expressions (CTEs)
- Ranking Functions
- Moving Average Calculations
- Complex JOIN Operations
- Business Report Generation
- Analytical SQL Techniques
- Real-world SQL Problem Solving

---

# Future Improvements

The project can be enhanced further by implementing:

- Stored Procedures
- SQL Functions
- Database Views
- Materialized Views
- Index Optimization
- Query Performance Analysis
- Database Normalization Examples
- Transaction Management
- Trigger Examples
- PostgreSQL Performance Tuning

---

# Entity Relationship Diagram

The following ER Diagram represents the database structure used in this assignment.

![ER Diagram](doc/ER_Diagram.png)

---

# Screenshots

### 1. Categories Table

Sample records from the **Categories** table.

![Categories Table](screenshot/02_categories_data.png)

---

### 2. Products Table

Sample records from the **Products** table.

![Products Table](screenshot/03_products_data.png)

---

### 3. Customers Table

Sample records from the **Customers** table.

![Customers Table](screenshot/04_customers_data.png)

---

### 4. Sales Table

Sample records from the **Sales** table.

![Sales Table](screenshot/05_sales_data.png)

---

### 5. Query 1 – Top 3 Products

Top-performing products identified using Window Functions.

![Top Products](screenshot/06_query1_top3_products.png)

---

### 6. Query 2 – LAG() Function

Comparison of previous sales using the LAG() function.

![LAG Function](screenshot/07_query2_lag_function.png)

---

### 7. Query 3 – LEAD() Function

Comparison of upcoming sales values using the LEAD() function.

![LEAD Function](screenshot/08_query3_lead_function.png)

---

### 8. Query 4 – RANK() Function

Ranking products based on sales performance.

![RANK Function](screenshot/09_query4_rank_function.png)

---

### 9. Query 5 – PARTITION BY

Category-wise ranking using the PARTITION BY clause.

![Partition Rank](screenshot/10_query5_partition_rank.png)

---

### 10. Moving Average

Sales trend analysis using Moving Average.

![Moving Average](screenshot/11_moving_average.png)

---

### 11. ROW_NUMBER()

Unique row numbering using ROW_NUMBER().

![ROW_NUMBER](screenshot/12_row_number.png)

---

### 12. DENSE_RANK()

Ranking without skipping rank values.

![DENSE_RANK](screenshot/13_dense_rank.png)

---

### 13. Complex JOIN

Business report generated using multiple JOIN operations.

![Complex JOIN](screenshot/14_complex_join.png)

---

### 14. Customer Sales Summary

Customer-wise sales report.

![Customer Sales Summary](screenshot/15_customer_sales_summary.png)

---

### 15. Category Sales Summary

Category-wise sales analysis.

![Category Sales Summary](screenshot/16_category_sales_summary.png)

---

### 16. Customer Category Report

Customer purchases grouped by category.

![Customer Category Report](screenshot/17_customer_category_report.png)

---

### 17. Best Customer by City

Top-performing customer identified for each city.

![Best Customer City](screenshot/18_best_customer_city.png)

---

# Project Summary

This project demonstrates advanced SQL techniques using PostgreSQL to solve real-world business problems through analytical queries.

The implementation covers Window Functions, Common Table Expressions (CTEs), Aggregate Functions, Complex JOINs, Ranking Functions, and Moving Average calculations to generate meaningful business insights from relational data.

The project provides practical experience in SQL-based reporting and analytics, making it highly relevant for Data Engineering, Data Analytics, and Business Intelligence roles.

---

# Author

**Akash More**

**Data Engineer**

GitHub Repository:

https://github.com/Akash-web750/aws-data-engineering-assignments

---

# License

This project is licensed under the MIT License.

---

# Acknowledgement

This project was created for learning, portfolio development, interview preparation, and gaining practical experience with PostgreSQL and advanced SQL concepts used in modern Data Engineering projects.