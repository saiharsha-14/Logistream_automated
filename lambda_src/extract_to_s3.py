import json
import os
import urllib.request
import urllib.error
import boto3
from datetime import datetime

SHIPPO_TOKEN = os.environ.get("SHIPPO_TEST_TOKEN")
S3_BUCKET_NAME = os.environ.get("S3_BUCKET_NAME")

def lambda_handler(event, context):
    url = "https://api.goshippo.com/shipments?page=1&results=50"
    headers = {
        "Authorization": f"ShippoToken {SHIPPO_TOKEN}",
        "Content-Type": "application/json"
    }

    req = urllib.request.Request(url, headers=headers, method="GET")

    try:
        with urllib.request.urlopen(req) as response:
            if response.status != 200:
                raise Exception(f"Shippo API returned HTTP [{response.status}]")
            raw_body = response.read().decode("utf-8")
            data = json.loads(raw_body)
    except urllib.error.HTTPError as e:
        print(f"❌ Failed to fetch from Shippo API: {e}")
        raise e

    results = data.get("results", [])
    s3 = boto3.client("s3")
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    s3_key = f"raw_shipments/shippo_raw_{timestamp}.json"

    s3.put_object(
        Bucket=S3_BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(results, indent=2),
        ContentType="application/json"
    )

    print(f"✅ Staged {len(results)} records into s3://{S3_BUCKET_NAME}/{s3_key}")

    return {
        "statusCode": 200,
        "s3_bucket": S3_BUCKET_NAME,
        "s3_key": s3_key,
        "records_count": len(results)
    }