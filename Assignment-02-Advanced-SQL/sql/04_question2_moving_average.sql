-- =========================================================
-- Assignment 02 - Advanced SQL Transformations
-- File Name : 04_question2_moving_average.sql
-- Database  : PostgreSQL
-- Author    : Akash More
--
-- Concepts Covered:
-- 1. Moving Average
-- 2. Window Functions
-- 3. AVG()
-- 4. RANK()
-- 5. ROW_NUMBER()
-- 6. DENSE_RANK()
-- 7. PARTITION BY
-- =========================================================


-- =========================================================
-- Query 1
-- Calculate 3-Day Moving Average of Sales
-- Using AVG() Window Function
-- =========================================================

SELECT
    sale_id,
    sale_date,
    amount,

    ROUND
    (
        AVG(amount)
        OVER
        (
            ORDER BY sale_date
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS moving_average

FROM sales

ORDER BY
    sale_date;



-- =========================================================
-- Query 2
-- Display Top 3 Products in Each Category
-- Using CTE + RANK()
-- =========================================================

WITH product_sales AS
(
    SELECT
        c.category_name,
        p.product_name,
        SUM(s.amount) AS total_sales,

        RANK()
        OVER
        (
            PARTITION BY c.category_name
            ORDER BY SUM(s.amount) DESC
        ) AS sales_rank

    FROM sales s

    JOIN products p
        ON s.product_id = p.product_id

    JOIN categories c
        ON p.category_id = c.category_id

    GROUP BY
        c.category_name,
        p.product_name
)

SELECT
    category_name,
    product_name,
    total_sales,
    sales_rank

FROM product_sales

WHERE sales_rank <= 3

ORDER BY
    category_name,
    sales_rank;



-- =========================================================
-- Query 3
-- Assign Sequential Row Numbers to Products
-- Using ROW_NUMBER()
-- =========================================================

SELECT
    category_name,
    product_name,
    total_sales,

    ROW_NUMBER()
    OVER
    (
        PARTITION BY category_name
        ORDER BY total_sales DESC
    ) AS row_number

FROM
(
    SELECT
        c.category_name,
        p.product_name,
        SUM(s.amount) AS total_sales

    FROM sales s

    JOIN products p
        ON s.product_id = p.product_id

    JOIN categories c
        ON p.category_id = c.category_id

    GROUP BY
        c.category_name,
        p.product_name
) AS product_summary

ORDER BY
    category_name,
    row_number;



-- =========================================================
-- Query 4
-- Rank Products Using DENSE_RANK()
-- =========================================================

SELECT
    c.category_name,
    p.product_name,
    SUM(s.amount) AS total_sales,

    DENSE_RANK()
    OVER
    (
        PARTITION BY c.category_name
        ORDER BY SUM(s.amount) DESC
    ) AS dense_rank

FROM sales s

JOIN products p
    ON s.product_id = p.product_id

JOIN categories c
    ON p.category_id = c.category_id

GROUP BY
    c.category_name,
    p.product_name

ORDER BY
    c.category_name,
    dense_rank;



-- =========================================================
-- End of File
-- Assignment 02 - Question 2 Completed
-- =========================================================