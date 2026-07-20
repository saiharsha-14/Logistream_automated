import json
import os
import urllib.request
import urllib.error
import random

SHIPPO_TOKEN = os.environ.get("SHIPPO_TEST_TOKEN")

CITIES = ["Bhiwandi", "Mumbai", "Bengaluru", "Hyderabad", "Gurugram", "Chennai", "Delhi", "Kolkata"]

def generate_mock_shipment():
    origin, recipient = random.sample(CITIES, 2)
    return {
        "address_from": {
            "name": "Warehouse Hub",
            "street1": "123 Logistics Park",
            "city": origin,
            "state": "MH",
            "zip": "400001",
            "country": "IN"
        },
        "address_to": {
            "name": "Customer Recipient",
            "street1": "456 Delivery Lane",
            "city": recipient,
            "state": "KA",
            "zip": "560001",
            "country": "IN"
        },
        "parcels": [{
            "length": "10",
            "width": "8",
            "height": "6",
            "distance_unit": "in",
            "weight": str(round(random.uniform(2.5, 30.0), 2)),
            "mass_unit": "lb"
        }],
        "async": False
    }

def post_shipment_to_shippo():
    url = "https://api.goshippo.com/shipments/"
    headers = {
        "Authorization": f"ShippoToken {SHIPPO_TOKEN}",
        "Content-Type": "application/json"
    }

    payload = generate_mock_shipment()
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")

    with urllib.request.urlopen(req) as response:
        res_body = response.read().decode("utf-8")
        res_json = json.loads(res_body)
        return res_json.get("object_id")

def lambda_handler(event, context):
    # Determine records count: default to 5 for initial setup/bootstrap, or 1 for regular daily runs
    records_to_create = 5 if event.get("bootstrap", False) else event.get("count", 5)
    
    created_ids = []
    print(f"🚀 Initializing seed batch. Generating {records_to_create} test shipments...")

    for i in range(records_to_create):
        try:
            shipment_id = post_shipment_to_shippo()
            if shipment_id:
                created_ids.append(shipment_id)
                print(f"  [{i+1}/{records_to_create}] Created shipment ID: {shipment_id}")
        except urllib.error.HTTPError as e:
            print(f"  ❌ HTTP Error on shipment {i+1}: {e.read().decode('utf-8')}")

    return {
        "statusCode": 200,
        "message": f"Successfully seeded {len(created_ids)} test shipments into Shippo API.",
        "created_shipment_ids": created_ids
    }