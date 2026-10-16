resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.name_prefix}-db-subnets" }
}

resource "aws_db_instance" "this" {
  identifier                   = "${var.name_prefix}-postgres"
  engine                       = "postgres"
  instance_class               = var.db_instance_class
  allocated_storage            = 20
  max_allocated_storage        = 25
  storage_type                 = "gp3"
  storage_encrypted            = true
  db_name                      = "mattermost"
  username                     = "mmuser"
  password                     = var.database_password
  port                         = 5432
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [var.database_security_group_id]
  publicly_accessible          = false
  multi_az                     = false
  backup_retention_period      = 1
  auto_minor_version_upgrade   = true
  deletion_protection          = false
  skip_final_snapshot          = true
  apply_immediately            = true
  performance_insights_enabled = false
  tags                         = { Name = "${var.name_prefix}-postgres" }
}
