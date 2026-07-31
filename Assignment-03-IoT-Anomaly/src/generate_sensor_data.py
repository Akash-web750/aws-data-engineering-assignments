import random
from datetime import datetime, timedelta

import pandas as pd

# ==========================================================
# Configuration
# ==========================================================

NUMBER_OF_RECORDS = 1000

START_TIME = datetime(2026, 8, 1, 0, 0, 0)

MIN_TEMPERATURE = 22.0
MAX_TEMPERATURE = 38.0

OUTPUT_FILE = "data/raw/sensor_data.csv"

LATE_EVENT_PERCENTAGE = 5
BACKDATED_EVENT_PERCENTAGE = 3
ANOMALY_PERCENTAGE = 1

# ==========================================================
# Device Information
# ==========================================================

DEVICES = {
    "DEV001": "Pune",
    "DEV002": "Mumbai",
    "DEV003": "Nashik",
    "DEV004": "Nagpur",
    "DEV005": "Chhatrapati Sambhajinagar"
}

# ==========================================================
# Generate Sensor Data
# ==========================================================

def generate_sensor_data():
    """
    Generate synthetic IoT sensor data with:
    - Normal Events
    - Backdated Events
    - Late Arriving Events
    - Temperature Anomalies
    """

    sensor_data = []

    current_time = START_TIME

    normal_count = 0
    late_count = 0
    backdated_count = 0
    anomaly_count = 0

    for _ in range(NUMBER_OF_RECORDS):

        device_id = random.choice(list(DEVICES.keys()))
        location = DEVICES[device_id]

        event_time = current_time
        arrival_time = current_time

        temperature = round(
            random.uniform(
                MIN_TEMPERATURE,
                MAX_TEMPERATURE
            ),
            2
        )

        event_type = "NORMAL"

        # ------------------------------------------
        # Sensor Anomaly
        # ------------------------------------------

        if random.randint(1, 100) <= ANOMALY_PERCENTAGE:

            temperature = round(
                random.uniform(70, 110),
                2
            )

            event_type = "SENSOR_ANOMALY"
            anomaly_count += 1

        # ------------------------------------------
        # Backdated Event
        # ------------------------------------------

        elif random.randint(1, 100) <= BACKDATED_EVENT_PERCENTAGE:

            event_time = current_time - timedelta(
                minutes=random.randint(5, 30)
            )

            event_type = "BACKDATED"
            backdated_count += 1

        # ------------------------------------------
        # Late Arriving Event
        # ------------------------------------------

        elif random.randint(1, 100) <= LATE_EVENT_PERCENTAGE:

            arrival_time = current_time + timedelta(
                minutes=random.randint(2, 10)
            )

            event_type = "LATE"

            late_count += 1

        else:
            normal_count += 1

        sensor_data.append({

            "device_id": device_id,

            "location": location,

            "timestamp": event_time,

            "arrival_time": arrival_time,

            "reading_value": temperature,

            "event_type": event_type

        })

        current_time += timedelta(minutes=1)

    df = pd.DataFrame(sensor_data)

    df.to_csv(
        OUTPUT_FILE,
        index=False
    )

    print("\n" + "=" * 65)
    print("      IoT Sensor Data Generated Successfully")
    print("=" * 65)

    print(f"Total Records          : {len(df)}")
    print(f"Normal Events          : {normal_count}")
    print(f"Late Arriving Events   : {late_count}")
    print(f"Backdated Events       : {backdated_count}")
    print(f"Sensor Anomalies       : {anomaly_count}")

    print(f"\nOutput File : {OUTPUT_FILE}")

    print("=" * 65)


# ==========================================================
# Main
# ==========================================================

if __name__ == "__main__":
    generate_sensor_data()