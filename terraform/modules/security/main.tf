resource "aws_security_group" "application" {
  name        = "${var.name_prefix}-application-sg"
  description = "Mattermost HTTP ingress and unrestricted outbound for updates and AWS APIs."
  vpc_id      = var.vpc_id
  ingress {
    description = "Mattermost HTTP for academic demo; restrict CIDR for real use."
    from_port   = 8065
    to_port     = 8065
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-application-sg" }
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-database-sg"
  description = "PostgreSQL is reachable only from Mattermost application instances."
  vpc_id      = var.vpc_id
  ingress {
    description     = "PostgreSQL from application security group"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-database-sg" }
}
