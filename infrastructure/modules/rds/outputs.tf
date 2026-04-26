output "db_host"          { value = aws_db_instance.this.address }
output "secret_arn"       { value = aws_secretsmanager_secret.db.arn }
output "secret_name"      { value = aws_secretsmanager_secret.db.name }