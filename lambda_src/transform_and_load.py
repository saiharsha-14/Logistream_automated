import os
import json
import boto3
import pymysql

s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucket_name = os.environ['S3_BUCKET_NAME']
    rds_host = os.environ['RDS_HOST']
    rds_user = os.environ['RDS_USER']
    rds_password = os.environ['RDS_PASSWORD']
    rds_db_name = os.environ['RDS_DB_NAME']
    
    # Strip port if present in host string
    if ":" in rds_host:
        rds_host = rds_host.split(":")[0]

    conn = pymysql.connect(
        host=rds_host,
        user=rds_user,
        password=rds_password,
        database=rds_db_name,
        connect_timeout=10
    )
    
    cursor = conn.cursor()

    # 1. AUTO-CREATE TABLE IF IT DOES NOT EXIST
    create_table_sql = """
    CREATE TABLE IF NOT EXISTS shipments (
        shipment_id VARCHAR(100) PRIMARY KEY,
        origin_city VARCHAR(100),
        recipient_city VARCHAR(100),
        recipient_country VARCHAR(10) DEFAULT 'IN',
        weight_lb DECIMAL(10, 2),
        shipment_date DATE,
        status VARCHAR(50)
    );
    """
    cursor.execute(create_table_sql)

    # 2. READ LATEST RAW FILE FROM S3
    response = s3.list_objects_v2(Bucket=bucket_name, Prefix="raw_shipments/")
    if 'Contents' not in response:
        return {"statusCode": 200, "body": "No files found in S3 to process."}

    latest_file = sorted(response['Contents'], key=lambda x: x['LastModified'], reverse=True)[0]['Key']
    file_obj = s3.get_object(Bucket=bucket_name, Key=latest_file)
    raw_data = json.loads(file_obj['Body'].read().decode('utf-8'))

    # 3. TRANSFORM & LOAD INTO MYSQL
    inserted_count = 0
    for record in raw_data:
        # Map fields dynamically based on Shippo payload shape
        shipment_id = record.get('object_id') or record.get('shipment_id')
        address_from = record.get('address_from', {})
        address_to = record.get('address_to', {})
        
        origin_city = address_from.get('city') if isinstance(address_from, dict) else record.get('origin_city', 'Unknown')
        recipient_city = address_to.get('city') if isinstance(address_to, dict) else record.get('recipient_city', 'Unknown')
        weight = record.get('weight') or record.get('weight_lb', 5.0)
        status = record.get('status', 'SUCCESS')
        
        insert_sql = """
        INSERT INTO shipments (shipment_id, origin_city, recipient_city, recipient_country, weight_lb, shipment_date, status)
        VALUES (%s, %s, %s, 'IN', %s, CURDATE(), %s)
        ON DUPLICATE KEY UPDATE status=VALUES(status);
        """
        cursor.execute(insert_sql, (shipment_id, origin_city, recipient_city, weight, status))
        inserted_count += 1

    conn.commit()
    cursor.close()
    conn.close()

    return {
        "statusCode": 200,
        "body": json.dumps(f"Successfully processed {inserted_count} records into RDS MySQL from {latest_file}.")
    }