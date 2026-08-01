import os
import pandas as pd

# ==========================================================
# Assignment 04 - Predictive Modelling with Pandas
# File Name : data_preprocessing.py
# Author    : Akash More
# ==========================================================

# ==========================================================
# Project Paths
# ==========================================================

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RAW_DATA_PATH = os.path.join(
    BASE_DIR,
    "data",
    "raw",
    "train.csv"
)

PROCESSED_DATA_PATH = os.path.join(
    BASE_DIR,
    "data",
    "processed",
    "titanic_cleaned.csv"
)

# ==========================================================
# Create Processed Folder
# ==========================================================

os.makedirs(
    os.path.dirname(PROCESSED_DATA_PATH),
    exist_ok=True
)

# ==========================================================
# Check Input File
# ==========================================================

if not os.path.exists(RAW_DATA_PATH):
    raise FileNotFoundError(
        f"\nInput file not found:\n{RAW_DATA_PATH}"
    )

# ==========================================================
# Load Dataset
# ==========================================================

print("=" * 60)
print("Loading Titanic Dataset...")
print("=" * 60)

df = pd.read_csv(RAW_DATA_PATH)

# ==========================================================
# Basic Information
# ==========================================================

print("\nDataset Shape")
print(df.shape)

print("\nColumns")
print(df.columns.tolist())

print("\nFirst Five Records")
print(df.head())

print("\nDataset Information")
df.info()

print("\nMissing Values")
print(df.isnull().sum())

# ==========================================================
# Data Cleaning
# ==========================================================

print("\nCleaning Dataset...")

# Fill missing Age using Median
df["Age"] = df["Age"].fillna(df["Age"].median())

# Fill missing Embarked using Mode
df["Embarked"] = df["Embarked"].fillna(
    df["Embarked"].mode()[0]
)

# Drop Cabin because it contains too many missing values
df.drop(
    columns=["Cabin"],
    inplace=True
)

# Drop unnecessary columns
df.drop(
    columns=[
        "PassengerId",
        "Name",
        "Ticket"
    ],
    inplace=True
)

# ==========================================================
# Encoding
# ==========================================================

print("\nEncoding Categorical Columns...")

# Male = 1
# Female = 0

df["Sex"] = df["Sex"].map({
    "male": 1,
    "female": 0
})

# Southampton = 0
# Cherbourg = 1
# Queenstown = 2

df["Embarked"] = df["Embarked"].map({
    "S": 0,
    "C": 1,
    "Q": 2
})

# ==========================================================
# Save Clean Dataset
# ==========================================================

print("\nSaving Cleaned Dataset...")

df.to_csv(
    PROCESSED_DATA_PATH,
    index=False
)

# ==========================================================
# Final Information
# ==========================================================

print("\nCleaned Dataset Shape")
print(df.shape)

print("\nRemaining Missing Values")
print(df.isnull().sum())

print("\nFirst Five Cleaned Records")
print(df.head())

print("\nDataset Saved Successfully")

print(f"\nOutput File : {PROCESSED_DATA_PATH}")

print("=" * 60)
print("Data Preprocessing Completed Successfully")
print("=" * 60)