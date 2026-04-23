output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Elastic IP address"
  value       = aws_eip.app.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to instance"
  value       = "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_eip.app.public_ip}"
}

output "agentlens_url" {
  description = "AgentLens pipeline debugger URL"
  value       = "https://agentlens.example.com"
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.app.id
}
