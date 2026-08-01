import os
import joblib
import pandas as pd

# ==========================================================
# Assignment 04 - Prediction
# File Name : predict.py
# Author    : Akash More
# ==========================================================

# ==========================================================
# Project Paths
# ==========================================================

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODEL_PATH = os.path.join(
    BASE_DIR,
    "models",
    "titanic_model.pkl"
)

# ==========================================================
# Load Trained Model
# ==========================================================

print("=" * 60)
print("Loading Titanic Prediction Model...")
print("=" * 60)

model = joblib.load(MODEL_PATH)

print("\nModel Loaded Successfully")

# ==========================================================
# Sample Passenger Data
# ==========================================================

sample_passenger = pd.DataFrame(
    [
        {
            "Pclass": 1,
            "Sex": 0,
            "Age": 28,
            "SibSp": 0,
            "Parch": 0,
            "Fare": 85.50,
            "Embarked": 1
        }
    ]
)

print("\nPassenger Details")
print(sample_passenger)

# ==========================================================
# Prediction
# ==========================================================

prediction = model.predict(sample_passenger)[0]

probability = model.predict_proba(sample_passenger)[0]

# ==========================================================
# Result
# ==========================================================

print("\nPrediction Result")

if prediction == 1:
    print("Passenger is likely to SURVIVE")
else:
    print("Passenger is likely to NOT SURVIVE")

print(f"\nSurvival Probability     : {probability[1]*100:.2f}%")
print(f"Non-Survival Probability : {probability[0]*100:.2f}%")

print("=" * 60)
print("Prediction Completed Successfully")
print("=" * 60)