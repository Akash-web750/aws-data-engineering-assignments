-- =========================================================
-- Assignment 02 - Advanced SQL Transformations
-- File Name : 03_question1_window_functions.sql
-- Database  : PostgreSQL
-- Author    : Akash More
--
-- Concepts Covered:
-- 1. Common Table Expression (CTE)
-- 2. RANK()
-- 3. LAG()
-- 4. LEAD()
-- 5. PARTITION BY
-- 6. ORDER BY
-- =========================================================


-- =========================================================
-- Query 1
-- Top 3 Products in Each Category
-- Using CTE + RANK()
-- =========================================================

WITH product_sales AS
(
    SELECT
        c.category_name,
        p.product_name,
        SUM(s.amount) AS total_sales,
        RANK() OVER
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
-- Query 2
-- Display Previous Sale Amount
-- Using LAG()
-- =========================================================

SELECT
    sale_id,
    sale_date,
    amount,

    LAG(amount)
    OVER
    (
        ORDER BY sale_date
    ) AS previous_sale

FROM sales;



-- =========================================================
-- Query 3
-- Display Next Sale Amount
-- Using LEAD()
-- =========================================================

SELECT
    sale_id,
    sale_date,
    amount,

    LEAD(amount)
    OVER
    (
        ORDER BY sale_date
    ) AS next_sale

FROM sales;



-- =========================================================
-- Query 4
-- Rank Sales Based on Amount
-- Using RANK()
-- =========================================================

SELECT
    sale_id,
    sale_date,
    amount,

    RANK()
    OVER
    (
        ORDER BY amount DESC
    ) AS sale_rank

FROM sales;



-- =========================================================
-- Query 5
-- Rank Products Within Each Category
-- Using RANK() + PARTITION BY
-- =========================================================

SELECT
    c.category_name,
    p.product_name,
    s.amount,

    RANK()
    OVER
    (
        PARTITION BY c.category_name
        ORDER BY s.amount DESC
    ) AS category_rank

FROM sales s

JOIN products p
    ON s.product_id = p.product_id

JOIN categories c
    ON p.category_id = c.category_id

ORDER BY
    c.category_name,
    category_rank;


-- =========================================================
-- Query 6 (Optional)
-- Rank Products by Total Sales Within Each Category
-- Using CTE + RANK()
-- =========================================================

WITH category_product_sales AS
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
)

SELECT
    category_name,
    product_name,
    total_sales,
    RANK() OVER
    (
        PARTITION BY category_name
        ORDER BY total_sales DESC
    ) AS category_rank
FROM category_product_sales
ORDER BY
    category_name,
    category_rank;


-- =========================================================
-- End of File
-- Assignment 02 - Question 1 Completed
-- =========================================================