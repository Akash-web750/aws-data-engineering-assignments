-- =========================================================
-- Assignment 02 - Advanced SQL Transformations
-- File Name : 05_question3_complex_join.sql
-- Database  : PostgreSQL
-- Author    : Akash More
--
-- Concepts Covered:
-- 1. INNER JOIN
-- 2. Complex JOIN
-- 3. GROUP BY
-- 4. Aggregate Functions
-- 5. Common Table Expression (CTE)
-- 6. RANK()
-- 7. PARTITION BY
-- =========================================================


-- =========================================================
-- Query 1
-- Display Complete Sales Report
-- Using Complex JOIN
-- =========================================================

SELECT
    c.customer_name,
    c.city,
    cat.category_name,
    p.product_name,
    s.sale_date,
    s.quantity,
    s.amount

FROM sales s

JOIN customers c
    ON s.customer_id = c.customer_id

JOIN products p
    ON s.product_id = p.product_id

JOIN categories cat
    ON p.category_id = cat.category_id

ORDER BY
    s.sale_date;



-- =========================================================
-- Query 2
-- Customer-wise Sales Summary
-- =========================================================

SELECT
    c.customer_name,
    c.city,
    COUNT(s.sale_id) AS total_orders,
    SUM(s.quantity) AS total_quantity,
    SUM(s.amount) AS total_sales

FROM customers c

JOIN sales s
    ON c.customer_id = s.customer_id

GROUP BY
    c.customer_name,
    c.city

ORDER BY
    total_sales DESC;



-- =========================================================
-- Query 3
-- Category-wise Sales Summary
-- =========================================================

SELECT
    cat.category_name,
    COUNT(s.sale_id) AS total_orders,
    SUM(s.quantity) AS total_quantity,
    SUM(s.amount) AS total_sales

FROM sales s

JOIN products p
    ON s.product_id = p.product_id

JOIN categories cat
    ON p.category_id = cat.category_id

GROUP BY
    cat.category_name

ORDER BY
    total_sales DESC;



-- =========================================================
-- Query 4
-- Customer-wise Category Sales Report
-- =========================================================

SELECT
    c.customer_name,
    cat.category_name,
    COUNT(s.sale_id) AS total_orders,
    SUM(s.quantity) AS total_quantity,
    SUM(s.amount) AS total_sales

FROM sales s

JOIN customers c
    ON s.customer_id = c.customer_id

JOIN products p
    ON s.product_id = p.product_id

JOIN categories cat
    ON p.category_id = cat.category_id

GROUP BY
    c.customer_name,
    cat.category_name

ORDER BY
    c.customer_name,
    total_sales DESC;



-- =========================================================
-- Query 5
-- Best Customer in Each City
-- Using CTE + RANK()
-- =========================================================

WITH customer_sales AS
(
    SELECT
        c.city,
        c.customer_name,
        SUM(s.amount) AS total_sales,

        RANK()
        OVER
        (
            PARTITION BY c.city
            ORDER BY SUM(s.amount) DESC
        ) AS sales_rank

    FROM customers c

    JOIN sales s
        ON c.customer_id = s.customer_id

    GROUP BY
        c.city,
        c.customer_name
)

SELECT
    city,
    customer_name,
    total_sales,
    sales_rank

FROM customer_sales

WHERE sales_rank = 1

ORDER BY
    city;



-- =========================================================
-- End of File
-- Assignment 02 - Question 3 Completed
-- =========================================================