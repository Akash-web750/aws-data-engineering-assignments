import os
import joblib
import pandas as pd

from sklearn.model_selection import train_test_split
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    confusion_matrix,
    classification_report
)

# ==========================================================
# Assignment 04 - Train Predictive Model
# File Name : train_model.py
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

MODEL_DIR = os.path.join(
    BASE_DIR,
    "models"
)

MODEL_FILE = os.path.join(
    MODEL_DIR,
    "titanic_model.pkl"
)

os.makedirs(MODEL_DIR, exist_ok=True)

# ==========================================================
# Load Dataset
# ==========================================================

print("=" * 60)
print("Loading Cleaned Titanic Dataset...")
print("=" * 60)

df = pd.read_csv(INPUT_FILE)

# ==========================================================
# Features and Target
# ==========================================================

X = df.drop("Survived", axis=1)

y = df["Survived"]

print("\nFeatures")
print(X.columns.tolist())

print("\nTarget")
print("Survived")

# ==========================================================
# Train Test Split
# ==========================================================

X_train, X_test, y_train, y_test = train_test_split(
    X,
    y,
    test_size=0.20,
    random_state=42
)

print("\nTraining Records :", len(X_train))
print("Testing Records  :", len(X_test))

# ==========================================================
# Train Model
# ==========================================================

print("\nTraining Logistic Regression Model...")

model = LogisticRegression(max_iter=1000)

model.fit(X_train, y_train)

# ==========================================================
# Prediction
# ==========================================================

predictions = model.predict(X_test)

# ==========================================================
# Model Evaluation
# ==========================================================

accuracy = accuracy_score(
    y_test,
    predictions
)

print("\nModel Accuracy")

print(f"{accuracy*100:.2f}%")

print("\nConfusion Matrix")

print(
    confusion_matrix(
        y_test,
        predictions
    )
)

print("\nClassification Report")

print(
    classification_report(
        y_test,
        predictions
    )
)

# ==========================================================
# Save Model
# ==========================================================

joblib.dump(
    model,
    MODEL_FILE
)

print("\nModel Saved Successfully")

print(MODEL_FILE)

print("=" * 60)
print("Model Training Completed Successfully")
print("=" * 60)