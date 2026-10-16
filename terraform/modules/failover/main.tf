data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/failover.py"
  output_path = "${path.module}/lambda/failover.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-failover-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "failover" {
  name = "${var.name_prefix}-failover-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeAddresses", "ec2:DescribeInstances", "ec2:StartInstances", "ec2:AssociateAddress", "ssm:SendCommand", "ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.notification_topic_arn
      }
    ]
  })
}
resource "aws_lambda_function" "failover" {
  function_name                  = "${var.name_prefix}-failover"
  role                           = aws_iam_role.lambda.arn
  handler                        = "failover.lambda_handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  timeout                        = 240
  reserved_concurrent_executions = 1
  memory_size                    = 128
  environment {
    variables = {
      PRIMARY_INSTANCE_ID = var.primary_instance_id
      STANDBY_INSTANCE_ID = var.standby_instance_id
      EIP_ALLOCATION_ID   = var.elastic_ip_allocation_id
      SNS_TOPIC_ARN       = var.notification_topic_arn
    }
  }
  tags       = { Name = "${var.name_prefix}-failover" }
  depends_on = [aws_cloudwatch_log_group.lambda]
}
resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.name_prefix}-health-check-schedule"
  description         = "Check Mattermost health and move the Elastic IP to standby after repeated failures."
  schedule_expression = "rate(1 minute)"
}
resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "${var.name_prefix}-failover-lambda"
  arn       = aws_lambda_function.failover.arn
}
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-failover"
  retention_in_days = 7
}
