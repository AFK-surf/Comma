variable "workspace_guard" {
  type        = string
  default     = "default"
  description = "Internal guard that prevents split ownership across Terraform workspaces."

  validation {
    condition     = var.workspace_guard == "default" && terraform.workspace == "default"
    error_message = "Only the default Terraform workspace may manage Comma Grafana alerting resources."
  }
}
