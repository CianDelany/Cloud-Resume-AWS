# 0. Creating a tf state vault for terraform and github
terraform {
  backend "s3" {
    bucket         = "cian-terraform-state-vault" # Create this bucket MANUALLY in the AWS Console first!
    key            = "terraform.tfstate"
    region         = "eu-north-1"
  }
}

provider "aws" {
  region = "eu-north-1"
}

# 1. The Storage (S3) - THIS STAYS!
resource "aws_s3_bucket" "cv_bucket" {
  bucket = "cian-delany-cv-2026" 
}

# 2. The File Upload
resource "aws_s3_object" "upload_cv" {
  bucket       = aws_s3_bucket.cv_bucket.id
  key          = "index.html"
  source       = "index.html"
  content_type = "text/html" # Crucial so it renders as a page
  
  # We add a source hash to track changes to the index.html file making apply recognize updates
  source_hash = filemd5("index.html")
}

# 3. The Origin Access Control (Secures the bucket)
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 4. The CloudFront Distribution (The Global URL)
resource "aws_cloudfront_distribution" "cv_distribution" {
  origin {
    domain_name              = aws_s3_bucket.cv_bucket.bucket_regional_domain_name
    origin_id                = "S3-CianCV"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-CianCV"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
# 5. This block attaches the policy to the bucket
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cv_bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cv_distribution.arn]
    }
  }
}
resource "aws_s3_bucket_policy" "cv_bucket_policy" {
  bucket = aws_s3_bucket.cv_bucket.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

# --- BACKEND SECTION ---

# 6. The Database (DynamoDB)
resource "aws_dynamodb_table" "visitor_counter" {
  name           = "cloud-resume-stats"
  billing_mode   = "PAY_PER_REQUEST" 
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S" 
  }
}

# 7. Initialize the Database Item
resource "aws_dynamodb_table_item" "init_count" {
  table_name = aws_dynamodb_table.visitor_counter.name
  hash_key   = aws_dynamodb_table.visitor_counter.hash_key

  item = <<ITEM
{
  "id": {"S": "visitors"},
  "count": {"N": "0"}
}
ITEM
}

# 8. Create a ZIP of the python code (Lambda Requires a ZIP)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "lambda_function.zip"
}

# 9. Define the IAM Role (What the Lambda is allowed to do)
resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# 10. Policy to allow Lambda to talk to DynamoDB
resource "aws_iam_role_policy" "dynamodb_lambda_policy" {
  name = "dynamodb_lambda_policy"
  role = aws_iam_role.iam_for_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
      Resource = aws_dynamodb_table.visitor_counter.arn
    }]
  })
}

# 11. The actual Lambda Function
resource "aws_lambda_function" "visitor_counter_lambda" {
  filename      = "lambda_function.zip"
  function_name = "visitor_counter_function"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# 12. Create the API
resource "aws_apigatewayv2_api" "visitor_api" {
  name          = "visitor_counter_api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"] # In production, you'd restrict this to your domain
    allow_methods = ["GET"]
  }
}

# 13. Create the Stage (The "Live" environment)
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.visitor_api.id
  name        = "$default"
  auto_deploy = true
}

# 14. Connect API Gateway to Lambda
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.visitor_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.visitor_counter_lambda.invoke_arn
}

# 15. Create the Route (The path /visitors)
resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.visitor_api.id
  route_key = "GET /visitors"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# 16. Permission for API Gateway to call Lambda
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.visitor_api.execution_arn}/*/*"
}

# 17. Output the API URL so we can use it
output "api_url" {
  value = "${aws_apigatewayv2_api.visitor_api.api_endpoint}/visitors"
}