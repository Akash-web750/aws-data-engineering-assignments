# Dataset Information

## Overview

This project uses a sample retail sales dataset created for practicing advanced SQL transformations in PostgreSQL.

## Tables

### 1. Categories

Stores product categories.

| Column | Data Type |
|---------|-----------|
| category_id | SERIAL |
| category_name | VARCHAR(100) |

Records: **5**

---

### 2. Products

Stores product details.

| Column | Data Type |
|---------|-----------|
| product_id | SERIAL |
| product_name | VARCHAR(100) |
| category_id | INT (Foreign Key) |

Records: **20**

---

### 3. Customers

Stores customer information.

| Column | Data Type |
|---------|-----------|
| customer_id | SERIAL |
| customer_name | VARCHAR(100) |
| city | VARCHAR(100) |

Records: **30**

---

### 4. Sales

Stores sales transactions.

| Column | Data Type |
|---------|-----------|
| sale_id | SERIAL |
| sale_date | DATE |
| customer_id | INT (Foreign Key) |
| product_id | INT (Foreign Key) |
| quantity | INT |
| amount | DECIMAL(10,2) |

Records: **100**

---

## Dataset Summary

| Table | Records |
|--------|--------:|
| Categories | 5 |
| Products | 20 |
| Customers | 30 |
| Sales | 100 |

Total Records: **155**

---

## Relationships

- One Category → Many Products
- One Product → Many Sales
- One Customer → Many Sales

---

## Purpose

This dataset is designed to practice:

- Common Table Expressions (CTE)
- Window Functions
- RANK()
- DENSE_RANK()
- ROW_NUMBER()
- LEAD()
- LAG()
- Moving Average
- Aggregate Functions
- Complex JOINs