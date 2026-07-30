![AWS](https://img.shields.io/badge/AWS-S3%20%7C%20Lambda-orange)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-SQL-blue)
![Python](https://img.shields.io/badge/Python-3.12-blue)
![GitHub](https://img.shields.io/badge/GitHub-Portfolio-black)
![License](https://img.shields.io/badge/License-MIT-green)

# AWS Data Engineering Assignments

A collection of hands-on Data Engineering projects demonstrating real-world implementation using AWS Cloud, PostgreSQL, Python, SQL, Pandas, and Machine Learning.

These assignments showcase practical knowledge of cloud-based data engineering, event-driven architecture, SQL analytics, ETL pipelines, automation, and data processing using industry-standard tools.

---

# Project Objective

The objective of this repository is to build practical Data Engineering solutions using modern cloud technologies and best engineering practices.

Each assignment focuses on solving real-world business problems while improving skills in SQL, cloud computing, automation, data transformation, and analytics.

---

# Assignment Status

| Assignment | Description | Status |
|------------|-------------|--------|
| Assignment 1 | AWS S3 Event-Driven CSV to JSON Pipeline using Lambda | ✅ Completed |
| Assignment 2 | Advanced SQL using CTEs, Window Functions and Complex JOINs | ✅ Completed |
| Assignment 3 | IoT Data Engineering and Anomaly Detection | ⏳ Planned |
| Assignment 4 | Predictive Analytics using Pandas and Scikit-Learn | ⏳ Planned |

---

# Repository Structure

```text
aws-data-engineering-assignments/
│
├── Assignment-01-S3-Lambda/
│   ├── input/
│   ├── output/
│   ├── screenshots/
│   ├── src/
│   ├── README.md
│   └── requirements.txt
│
├── Assignment-02-Advanced-SQL/
│   ├── sql/
│   ├── screenshots/
│   ├── docs/
│   └── README.md
│
├── Assignment-03-IoT-Anomaly/
│
├── Assignment-04-Pandas-ML/
│
├── datasets/
├── docs/
├── images/
├── README.md
├── requirements.txt
└── LICENSE
```

---

# Technologies Used

## Cloud

- Amazon S3
- AWS Lambda
- AWS IAM
- Amazon CloudWatch

## Database

- PostgreSQL

## Programming

- Python 3.12
- SQL

## Libraries

- Boto3
- Pandas
- NumPy
- Scikit-Learn

## Tools

- Git
- GitHub
- Visual Studio Code
- pgAdmin 4

---

# Skills Demonstrated

- Event-Driven Architecture
- AWS Lambda Development
- Amazon S3 Integration
- IAM Role Management
- CloudWatch Monitoring
- Python Automation
- CSV Processing
- JSON Data Transformation
- PostgreSQL
- SQL Query Development
- Window Functions
- Common Table Expressions (CTE)
- Complex JOINs
- Moving Average
- Analytical SQL
- Git Version Control
- Data Engineering Best Practices

---

# Completed Projects

## Assignment 1

### AWS S3 Event-Driven CSV to JSON Pipeline

#### Project Overview

This project automatically converts CSV files uploaded to an Amazon S3 bucket into JSON format using an AWS Lambda function.

Whenever a CSV file is uploaded to the input bucket, Amazon S3 triggers AWS Lambda. The Lambda function processes the CSV file, converts it into JSON format, and stores the output in another S3 bucket.

#### Technologies Used

- Amazon S3
- AWS Lambda
- IAM
- CloudWatch
- Python
- Boto3

---

## Assignment 2

### Advanced SQL Transformations

#### Project Overview

This project demonstrates advanced SQL concepts using PostgreSQL.

A retail sales dataset consisting of Categories, Products, Customers, and Sales tables is used to solve analytical business problems using SQL.

The project covers analytical SQL queries using Common Table Expressions (CTEs), Window Functions, Moving Average calculations, Ranking Functions, and Complex JOIN operations.

#### SQL Concepts Covered

- Common Table Expressions (CTE)
- Window Functions
- RANK()
- DENSE_RANK()
- ROW_NUMBER()
- LEAD()
- LAG()
- Moving Average
- Complex JOIN
- Aggregate Functions
- Analytical SQL

#### Technologies Used

- PostgreSQL
- SQL
- pgAdmin 4

---

# Upcoming Projects

## Assignment 3

### IoT Data Engineering

Topics include:

- Sensor Data Collection
- Data Cleaning
- Streaming Data Processing
- Feature Engineering
- Anomaly Detection

---

## Assignment 4

### Machine Learning Pipeline

Topics include:

- Pandas
- Data Cleaning
- Feature Engineering
- Model Training
- Model Evaluation
- Prediction Pipeline

---

# Future Enhancements

- Apache Airflow
- Apache Spark
- PySpark
- Apache Kafka
- Snowflake
- AWS Glue ETL Jobs
- Terraform
- Docker
- GitHub Actions CI/CD
- Unit Testing
- Data Validation Framework
- Monitoring and Alerting

---

# Quick Start

```bash
git clone https://github.com/<your-github-username>/aws-data-engineering-assignments.git

cd aws-data-engineering-assignments
```

Explore each assignment folder for source code, SQL scripts, documentation, and screenshots.

---

# Author

**Akash More**

Data Engineer

GitHub: https://github.com/Akash-web750/aws-data-engineering-assignments

---

# License

This project is licensed under the MIT License.

---

# Acknowledgement

This repository has been created for learning, portfolio development, interview preparation, and demonstrating practical Data Engineering skills using modern cloud technologies and industry-standard tools.