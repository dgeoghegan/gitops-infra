variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
  default     = "jb-demo"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  type        = list(string)
  description = "Managed node group instance types"
  default     = ["t3.small"]
}

variable "node_desired_size" {
  type        = number
  description = "Desired node count"
  default     = 2
}

variable "node_min_size" {
  type        = number
  description = "Min node count"
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Max node count"
  default     = 3
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default = {
    Project = "gitops-demo"
    Phase   = "phase1"
  }
}
