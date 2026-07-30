# Assignment 01 - AWS S3 Event-Driven CSV to JSON Pipeline

## Project Overview

This project demonstrates an event-driven data processing pipeline using Amazon S3 and AWS Lambda.

Whenever a CSV file is uploaded to the Amazon S3 input bucket, an AWS Lambda function is automatically triggered. The Lambda function reads the CSV file, converts it into JSON format, and stores the processed file in a separate Amazon S3 output bucket.

This project demonstrates practical implementation of AWS serverless architecture for automated data processing.

---

# Architecture

```text
                employees.csv
                      │
                      ▼
          Amazon S3 Input Bucket
                      │
          S3 Object Created Event
                      │
                      ▼
             AWS Lambda Function
          (CSV to JSON Conversion)
                      │
                      ▼
         Amazon S3 Output Bucket
               employees.json
```

---

# AWS Services Used

- Amazon S3
- AWS Lambda
- AWS IAM
- Amazon CloudWatch

---

# Technologies Used

- Python 3.12
- Boto3
- Git
- GitHub
- Visual Studio Code

---

# Project Structure

```text
Assignment-01-S3-Lambda/
│
├── input/
│   └── employees.csv
│
├── output/
│   └── employees.json
│
├── screenshots/
│   ├── lambda-function.png
│   ├── s3-input-bucket.png
│   ├── output-bucket.png
│   ├── event-notification.png
│   └── cloudwatch-logs.png
│
├── src/
│   └── lambda_function.py
│
├── requirements.txt
└── README.md
```

---

# Workflow

1. Upload a CSV file to the Amazon S3 input bucket.
2. Amazon S3 triggers the AWS Lambda function.
3. Lambda reads the uploaded CSV file.
4. CSV data is converted into JSON format.
5. JSON file is uploaded to the Amazon S3 output bucket.
6. Execution logs are stored in Amazon CloudWatch.

---

# Input File

### employees.csv

```csv
id,name,department,salary
1,Akash,IT,50000
2,Rahul,HR,45000
3,Priya,Finance,60000
4,Neha,Marketing,55000
```

---

# Output File

### employees.json

```json
[
    {
        "id": "1",
        "name": "Akash",
        "department": "IT",
        "salary": "50000"
    },
    {
        "id": "2",
        "name": "Rahul",
        "department": "HR",
        "salary": "45000"
    },
    {
        "id": "3",
        "name": "Priya",
        "department": "Finance",
        "salary": "60000"
    },
    {
        "id": "4",
        "name": "Neha",
        "department": "Marketing",
        "salary": "55000"
    }
]
```

---

# Lambda Function Responsibilities

- Receive Amazon S3 event notification.
- Read uploaded CSV file.
- Convert CSV records into JSON format.
- Upload JSON file to Amazon S3 output bucket.
- Generate execution logs in Amazon CloudWatch.

---

# Skills Demonstrated

- Event-Driven Architecture
- AWS Lambda
- Amazon S3
- IAM Role Configuration
- CloudWatch Logging
- Python Automation
- CSV Processing
- JSON Transformation
- Boto3 SDK
- Serverless Computing

---

# Screenshots

Store the following screenshots inside the **screenshots** folder.

- Lambda Function
- Amazon S3 Input Bucket
- Amazon S3 Output Bucket
- Event Notification
- CloudWatch Logs

Example:

```text
screenshots/
├── lambda-function.png
├── s3-input-bucket.png
├── output-bucket.png
├── event-notification.png
└── cloudwatch-logs.png
```

---

# requirements.txt

```text
boto3
```

---

# Future Improvements

- Process multiple CSV files.
- Add error handling for invalid CSV files.
- Store output using date-based folders.
- Compress output JSON files.
- Deploy using Terraform.
- Automate deployment using GitHub Actions.

---

# Learning Outcomes

This project helped in understanding:

- Amazon S3 Event Notifications
- AWS Lambda
- IAM Roles and Permissions
- Python Boto3 SDK
- Serverless Data Processing
- CloudWatch Monitoring
- Event-Driven Data Engineering

---

# Author

**Akash More**

Data Engineer

GitHub Portfolio Project

---

# License

This project is licensed under the MIT License.