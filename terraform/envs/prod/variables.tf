variable "project" {
  type    = string
  default = "edupulse"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  description = "true = one NAT (cheaper, an AZ outage cuts egress); false = one per AZ."
  type        = bool
  default     = false
}

variable "root_domain" {
  description = "Domain managed in Cloudflare. A wildcard certificate covers it and every subdomain."
  type        = string
  default     = "bishnuthapa.info.np"
}

variable "app_subdomains" {
  description = "Subdomains served by the web app, e.g. [\"app\"] => app.<root_domain>."
  type        = list(string)
  default     = ["app"]
}

variable "cloudflare_zone_id" {
  description = "Zone ID of root_domain (Cloudflare dashboard > the domain > Overview, right column)."
  type        = string
}

variable "github_repository" {
  description = "owner/repo allowed to deploy through OIDC."
  type        = string
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "infra_instance_type" {
  description = "Host for MySQL + Redis + RabbitMQ (about 300 MB RAM in use)."
  type        = string
  default     = "t3.small"
}

variable "infra_data_volume_gb" {
  type    = number
  default = 30
}

variable "alarm_email" {
  description = "Where CloudWatch alarms are sent. Empty = topic without subscriber."
  type        = string
  default     = ""
}

variable "owner" {
  description = "Team or person accountable for this stack (Owner tag)."
  type        = string
  default     = "devops"
}

variable "cost_center" {
  description = "Cost allocation label (CostCenter tag). Activate it as a cost allocation tag in Billing."
  type        = string
  default     = "edupulse"
}
