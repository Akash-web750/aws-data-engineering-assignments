# Database Schema

## Categories

| Column | Type |
|---------|------|
| category_id | SERIAL |
| category_name | VARCHAR(100) |

---

## Products

| Column | Type |
|---------|------|
| product_id | SERIAL |
| product_name | VARCHAR(100) |
| category_id | INT |

---

## Customers

| Column | Type |
|---------|------|
| customer_id | SERIAL |
| customer_name | VARCHAR(100) |
| city | VARCHAR(100) |

---

## Sales

| Column | Type |
|---------|------|
| sale_id | SERIAL |
| sale_date | DATE |
| customer_id | INT |
| product_id | INT |
| quantity | INT |
| amount | DECIMAL(10,2) |