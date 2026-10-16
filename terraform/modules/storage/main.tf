resource "random_id" "suffix" { byte_length = 4 }

resource "aws_s3_bucket" "files" {
  bucket        = "${var.name_prefix}-files-${random_id.suffix.hex}"
  force_destroy = true
  tags          = { Name = "${var.name_prefix}-files" }
}
resource "aws_s3_bucket_public_access_block" "files" {
  bucket                  = aws_s3_bucket.files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    id     = "expire-demo-objects"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
