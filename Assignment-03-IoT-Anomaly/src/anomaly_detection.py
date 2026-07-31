import pandas as pd

# ==========================================================
# Configuration
# ==========================================================

INPUT_FILE = "data/raw/sensor_data.csv"
OUTPUT_FILE = "data/processed/anomaly_report.csv"

Z_SCORE_THRESHOLD = 3

# ==========================================================
# Detect Anomalies
# ==========================================================

def detect_anomalies():

    # Read CSV
    df = pd.read_csv(INPUT_FILE)

    # Calculate Mean
    mean = df["reading_value"].mean()

    # Calculate Standard Deviation
    std = df["reading_value"].std()

    # Calculate Z-Score
    df["z_score"] = (
        (df["reading_value"] - mean) / std
    )

    # Mark Anomalies
    df["anomaly"] = df["z_score"].apply(
        lambda x: "YES"
        if abs(x) > Z_SCORE_THRESHOLD
        else "NO"
    )

    # Save Output
    df.to_csv(
        OUTPUT_FILE,
        index=False
    )

    # Summary
    total_records = len(df)
    anomaly_count = len(df[df["anomaly"] == "YES"])

    print("\n" + "=" * 60)
    print("IoT Sensor Anomaly Detection")
    print("=" * 60)

    print(f"Total Records       : {total_records}")
    print(f"Mean Temperature    : {mean:.2f}")
    print(f"Standard Deviation  : {std:.2f}")
    print(f"Anomalies Detected  : {anomaly_count}")

    print(f"\nOutput File : {OUTPUT_FILE}")

    print("=" * 60)

# ==========================================================
# Main
# ==========================================================

if __name__ == "__main__":
    detect_anomalies()