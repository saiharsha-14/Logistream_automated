terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "shippo_test_token" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type    = string
}

# ------------------------------------------------------------------------------
# 1. S3 Storage Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "raw_landing_zone" {
  bucket        = "logistream-raw-landing-zone-2026"
  force_destroy = true
}

# ------------------------------------------------------------------------------
# 2. Networking & Security
# ------------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_db_subnet_group" "rds_subnets" {
  name       = "logistream-rds-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "LogiStream RDS Subnet Group"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "logistream-rds-sg"
  description = "Allow inbound MySQL traffic from Lambda and local development"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# 3. AWS RDS MySQL Instance
# ------------------------------------------------------------------------------
resource "aws_db_instance" "mysql_rds" {
  identifier             = "logistics-db-instance"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "logistics_db"
  username               = "root"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  publicly_accessible    = true
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

# ------------------------------------------------------------------------------
# 4. IAM Roles & Policies
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name = "logistream_lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "logistream_lambda_policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.raw_landing_zone.arn}", "${aws_s3_bucket.raw_landing_zone.arn}/*"]
      },
      {
        Action   = ["sns:Publish"]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 5. Lambda Packaging & Functions
# ------------------------------------------------------------------------------
data "archive_file" "seed_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/seed_api.py"
  output_path = "${path.module}/seed_api.zip"
}

data "archive_file" "extract_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/extract_to_s3.py"
  output_path = "${path.module}/extract_to_s3.zip"
}

data "archive_file" "transform_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/transform_and_load.zip"
}

resource "aws_lambda_function" "seed_api" {
  filename         = data.archive_file.seed_zip.output_path
  function_name    = "LogiStream-SeedAPI"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "seed_api.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.seed_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SHIPPO_TEST_TOKEN = var.shippo_test_token
    }
  }
}

resource "aws_lambda_function" "extract_to_s3" {
  filename         = data.archive_file.extract_zip.output_path
  function_name    = "LogiStream-ExtractToS3"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "extract_to_s3.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.extract_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      SHIPPO_TEST_TOKEN = var.shippo_test_token
      S3_BUCKET_NAME    = aws_s3_bucket.raw_landing_zone.bucket
    }
  }
}

resource "aws_lambda_function" "transform_and_load" {
  filename         = data.archive_file.transform_zip.output_path
  function_name    = "LogiStream-TransformAndLoad"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "transform_and_load.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.transform_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.raw_landing_zone.bucket
      RDS_HOST       = aws_db_instance.mysql_rds.endpoint
      RDS_USER       = aws_db_instance.mysql_rds.username
      RDS_PASSWORD   = var.db_password
      RDS_DB_NAME    = aws_db_instance.mysql_rds.db_name
    }
  }
}
# ------------------------------------------------------------------------------
# 6. SNS Notifications
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "pipeline_alerts" {
  name = "logistream-pipeline-alerts"
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ------------------------------------------------------------------------------
# 7. AWS Step Functions Orchestrator
# ------------------------------------------------------------------------------
resource "aws_iam_role" "step_functions_role" {
  name = "logistream_step_functions_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "logistream_step_functions_policy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["lambda:InvokeFunction"]
        Effect   = "Allow"
        Resource = [
          aws_lambda_function.extract_to_s3.arn,
          aws_lambda_function.transform_and_load.arn
        ]
      },
      {
        Action   = ["sns:Publish"]
        Effect   = "Allow"
        Resource = aws_sns_topic.pipeline_alerts.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "pipeline_orchestrator" {
  name     = "LogiStreamPipelineOrchestrator"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "LogiStream ETL Orchestration Pipeline"
    StartAt = "ExtractFromAPI"
    States = {
      ExtractFromAPI = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.extract_to_s3.arn
        }
        Next = "TransformAndValidate"
      }
      TransformAndValidate = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.transform_and_load.arn
          "Payload.$"  = "$.Payload"
        }
        Next = "SendSuccessAlert"
      }
      SendSuccessAlert = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.pipeline_alerts.arn
          Subject  = "✅ LogiStream Pipeline Completed Successfully"
          Message  = "All API records extracted, validated, and loaded into RDS MySQL."
        }
        End = true
      }
    }
  })
}

# ------------------------------------------------------------------------------
# 8. EventBridge Schedules
# ------------------------------------------------------------------------------

# RULE 1: Daily Seed API Trigger @ 12 AM IST (18:30 UTC)
resource "aws_cloudwatch_event_rule" "daily_seed_trigger" {
  name                = "logistream-daily-seed-trigger"
  description         = "Triggers Seed API Lambda daily at 12 AM IST (18:30 UTC)"
  schedule_expression = "cron(30 18 * * ? *)"
}

resource "aws_cloudwatch_event_target" "seed_lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_seed_trigger.name
  target_id = "LogiStreamSeedLambda"
  arn       = aws_lambda_function.seed_api.arn
}

resource "aws_lambda_permission" "allow_eventbridge_to_seed" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.seed_api.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_seed_trigger.arn
}

# RULE 2: ETL Orchestrator Trigger Every 4 Hours
resource "aws_cloudwatch_event_rule" "every_4_hours_etl" {
  name                = "logistream-every-4-hours-etl"
  description         = "Triggers Step Functions ETL State Machine every 4 hours"
  schedule_expression = "cron(30 */4 * * ? *)"
}

resource "aws_iam_role" "eventbridge_sfn_role" {
  name = "logistream_eventbridge_sfn_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_sfn_policy" {
  name = "logistream_eventbridge_sfn_policy"
  role = aws_iam_role.eventbridge_sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "states:StartExecution"
      Effect   = "Allow"
      Resource = aws_sfn_state_machine.pipeline_orchestrator.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "orchestrator_target" {
  rule      = aws_cloudwatch_event_rule.every_4_hours_etl.name
  target_id = "LogiStreamPipelineOrchestrator"
  arn       = aws_sfn_state_machine.pipeline_orchestrator.arn
  role_arn  = aws_iam_role.eventbridge_sfn_role.arn
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------
output "s3_bucket_name" {
  value = aws_s3_bucket.raw_landing_zone.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.mysql_rds.endpoint
}

output "sns_topic_arn" {
  value = aws_sns_topic.pipeline_alerts.arn
}

output "step_functions_arn" {
  value = aws_sfn_state_machine.pipeline_orchestrator.arn
}
