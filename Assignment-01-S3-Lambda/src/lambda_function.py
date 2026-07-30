import json
import csv
import boto3
import io

# Create S3 client
s3 = boto3.client("s3")


def lambda_handler(event, context):
    try:

        # Read bucket name and file name from S3 Event
        input_bucket = event["Records"][0]["s3"]["bucket"]["name"]
        input_key = event["Records"][0]["s3"]["object"]["key"]

        print(f"Input Bucket : {input_bucket}")
        print(f"Input File   : {input_key}")

        # Read CSV file from S3
        response = s3.get_object(
            Bucket=input_bucket,
            Key=input_key
        )

        csv_content = response["Body"].read().decode("utf-8")

        # Convert CSV to JSON
        csv_reader = csv.DictReader(io.StringIO(csv_content))
        json_data = list(csv_reader)

        # Output bucket
        output_bucket = "akash-de-assignment-output-2026"

        # Output file name
        output_key = input_key.replace(".csv", ".json")

        # Upload JSON to Output Bucket
        s3.put_object(
            Bucket=output_bucket,
            Key=output_key,
            Body=json.dumps(json_data, indent=4),
            ContentType="application/json"
        )

        print("JSON file uploaded successfully.")

        return {
            "statusCode": 200,
            "body": json.dumps("CSV converted to JSON successfully")
        }

    except Exception as e:

        print("Error :", str(e))

        return {
            "statusCode": 500,
            "body": json.dumps(str(e))
        }