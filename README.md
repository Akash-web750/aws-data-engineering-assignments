![AWS](https://img.shields.io/badge/AWS-S3%20%7C%20Lambda-orange)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-SQL-blue)
![Python](https://img.shields.io/badge/Python-3.10+-blue)
![GitHub](https://img.shields.io/badge/GitHub-Portfolio-black)
![License](https://img.shields.io/badge/License-MIT-green)

# AWS Data Engineering Assignments

A collection of hands-on Data Engineering projects demonstrating real-world implementation using AWS Cloud, PostgreSQL, Python, SQL, Pandas, and Machine Learning.

These assignments showcase practical knowledge of cloud-based data engineering, event-driven architecture, SQL analytics, ETL pipelines, automation, data processing, and anomaly detection using industry-standard tools.

---

# Project Objective

The objective of this repository is to build practical Data Engineering solutions using modern cloud technologies and engineering best practices.

Each assignment focuses on solving real-world business problems while improving skills in SQL, cloud computing, automation, ETL, data transformation, analytics, and machine learning.

---

# Assignment Status

| Assignment | Description | Status |
|------------|-------------|--------|
| Assignment 1 | AWS S3 Event-Driven CSV to JSON Pipeline using Lambda | ✅ Completed |
| Assignment 2 | Advanced SQL using CTEs, Window Functions and Complex JOINs | ✅ Completed |
| Assignment 3 | IoT Data Engineering & Anomaly Detection | ✅ Completed |
| Assignment 4 | Predictive Modelling using Pandas & Machine Learning | ✅ Completed |

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
│   ├── data/
│   ├── docs/
│   ├── screenshots/
│   ├── src/
│   ├── README.md
│   └── requirements.txt
│
├── Assignment-04-Pandas-ML/
│   ├── data/
│   ├── models/
│   ├── screenshots/
│   ├── src/
│   ├── README.md
│   └── requirements.txt
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

- Python 3.10+
- SQL

## Libraries

- Boto3
- Pandas
- NumPy
- Scikit-Learn
- Matplotlib
- Joblib

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
- IoT Data Processing
- Time-Series Data Handling
- Statistical Anomaly Detection
- Z-Score Analysis
- Pandas Data Processing
- Git Version Control
- Data Engineering Best Practices
- Exploratory Data Analysis (EDA)
- Feature Engineering
- Logistic Regression
- Model Evaluation
- Classification Report
- Confusion Matrix
- Model Serialization
- Predictive Modelling

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

## Assignment 3

### IoT Data Engineering & Anomaly Detection

#### Project Overview

This project generates synthetic IoT sensor data from multiple devices and simulates real-world scenarios such as backdated events, late-arriving events, and abnormal sensor readings.

The generated dataset is analyzed using the Z-Score statistical method to detect anomalies and produce a processed anomaly report.

#### Features

- Generate synthetic IoT sensor data
- Simulate backdated events
- Simulate late-arriving events
- Inject sensor anomalies
- Detect anomalies using Z-Score
- Generate anomaly report

#### Technologies Used

- Python
- Pandas
- CSV
- Statistics

---


## Assignment 4

### Predictive Modelling with Pandas

#### Project Overview

This project demonstrates an end-to-end Machine Learning workflow using the Titanic dataset.

The project includes data preprocessing, feature engineering, exploratory data analysis (EDA), Logistic Regression model training, model evaluation, and passenger survival prediction.

The trained model is saved using Joblib and reused for future predictions.

#### Features

- Data Cleaning
- Missing Value Handling
- Feature Engineering
- Exploratory Data Analysis (EDA)
- Logistic Regression
- Model Evaluation
- Model Serialization
- Prediction Pipeline

#### Technologies Used

- Python
- Pandas
- NumPy
- Matplotlib
- Scikit-learn
- Joblib



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
git clone https://github.com/Akash-web750/aws-data-engineering-assignments.git

cd aws-data-engineering-assignments
```

Explore each assignment folder for source code, SQL scripts, documentation, and screenshots.

---

# Author

**Akash More**

Data Engineer

GitHub Repository:

https://github.com/Akash-web750/aws-data-engineering-assignments

---

# License

This project is licensed under the MIT License.

---

# Acknowledgement

This repository has been created for learning, portfolio development, interview preparation, and demonstrating practical Data Engineering skills using modern cloud technologies and industry-standard tools.