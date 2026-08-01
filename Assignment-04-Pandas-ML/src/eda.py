import os
import pandas as pd
import matplotlib.pyplot as plt

# ==========================================================
# Assignment 04 - Exploratory Data Analysis (EDA)
# File Name : eda.py
# Author    : Akash More
# ==========================================================

# ==========================================================
# Project Paths
# ==========================================================

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INPUT_FILE = os.path.join(
    BASE_DIR,
    "data",
    "processed",
    "titanic_cleaned.csv"
)

SCREENSHOT_DIR = os.path.join(
    BASE_DIR,
    "screenshots"
)

os.makedirs(SCREENSHOT_DIR, exist_ok=True)

# ==========================================================
# Load Dataset
# ==========================================================

print("=" * 60)
print("Titanic Dataset - Exploratory Data Analysis")
print("=" * 60)

df = pd.read_csv(INPUT_FILE)

# ==========================================================
# Dataset Summary
# ==========================================================

print("\nDataset Shape")
print(df.shape)

print("\nColumns")
print(df.columns.tolist())

print("\nData Types")
print(df.dtypes)

print("\nSummary Statistics")
print(df.describe())

print("\nMissing Values")
print(df.isnull().sum())

# ==========================================================
# Correlation
# ==========================================================

print("\nCorrelation Matrix")
print(df.corr())

# ==========================================================
# Chart 1 - Survival Count
# ==========================================================

plt.figure(figsize=(6,4))
df["Survived"].value_counts().sort_index().plot(kind="bar")
plt.title("Passenger Survival")
plt.xlabel("Survived (0 = No, 1 = Yes)")
plt.ylabel("Passengers")
plt.tight_layout()
plt.savefig(os.path.join(SCREENSHOT_DIR, "01_survival_count.png"))
plt.close()

# ==========================================================
# Chart 2 - Passenger Class
# ==========================================================

plt.figure(figsize=(6,4))
df["Pclass"].value_counts().sort_index().plot(kind="bar")
plt.title("Passenger Class Distribution")
plt.xlabel("Passenger Class")
plt.ylabel("Count")
plt.tight_layout()
plt.savefig(os.path.join(SCREENSHOT_DIR, "02_passenger_class.png"))
plt.close()

# ==========================================================
# Chart 3 - Gender Distribution
# ==========================================================

plt.figure(figsize=(6,4))
df["Sex"].value_counts().sort_index().plot(kind="bar")
plt.title("Gender Distribution")
plt.xlabel("Gender (0 = Female, 1 = Male)")
plt.ylabel("Count")
plt.tight_layout()
plt.savefig(os.path.join(SCREENSHOT_DIR, "03_gender_distribution.png"))
plt.close()

# ==========================================================
# Chart 4 - Age Distribution
# ==========================================================

plt.figure(figsize=(7,4))
plt.hist(df["Age"], bins=20)
plt.title("Age Distribution")
plt.xlabel("Age")
plt.ylabel("Passengers")
plt.tight_layout()
plt.savefig(os.path.join(SCREENSHOT_DIR, "04_age_distribution.png"))
plt.close()

# ==========================================================
# Chart 5 - Fare Distribution
# ==========================================================

plt.figure(figsize=(7,4))
plt.hist(df["Fare"], bins=20)
plt.title("Fare Distribution")
plt.xlabel("Fare")
plt.ylabel("Passengers")
plt.tight_layout()
plt.savefig(os.path.join(SCREENSHOT_DIR, "05_fare_distribution.png"))
plt.close()

# ==========================================================
# Chart 6 - Correlation Matrix
# ==========================================================

correlation = df.corr()

plt.figure(figsize=(8,6))
plt.imshow(correlation)
plt.colorbar()

plt.xticks(
    range(len(correlation.columns)),
    correlation.columns,
    rotation=90
)

plt.yticks(
    range(len(correlation.columns)),
    correlation.columns
)

plt.title("Correlation Matrix")

plt.tight_layout()

plt.savefig(
    os.path.join(
        SCREENSHOT_DIR,
        "06_correlation_matrix.png"
    )
)

plt.close()

# ==========================================================
# Console Output
# ==========================================================

print("\nEDA Completed Successfully")

print("\nCharts Saved In")

print(SCREENSHOT_DIR)

print("=" * 60)