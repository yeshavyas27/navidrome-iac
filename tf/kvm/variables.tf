variable "suffix" {
  description = "Suffix for resource names (use net ID + proj05)"
  type        = string
  default     = "proj05"
  nullable    = false
}

variable "key" {
  description = "Name of key pair"
  type        = string
  default     = "id_rsa_chameleon"
}

variable "reservation_id" {
  description = "Blazar reservation ID from KVM@TACC lease for CPU nodes — used as flavor_id for flavor:instance reservations"
  type        = string
}

variable "gpu_reservation_id" {
  description = "Optional: Blazar reservation ID for GPU node. If set, a GPU worker node will be provisioned."
  type        = string
  default     = ""
}

variable "nodes" {
  description = "Map of node names to private IPs (node1=control-plane, node2+=workers)"
  type        = map(string)
  default = {
    "node1" = "192.168.1.11"
    "node2" = "192.168.1.12"
  }
}

variable "gpu_nodes" {
  description = "Map of GPU node names to private IPs (optional)"
  type        = map(string)
  default = {
    # "node3" = "192.168.1.13"
  }
}

variable "sg_default_id" {
  description = "ID of the 'default' security group in your OpenStack project"
  type        = string
}

variable "sg_ssh_id" {
  description = "ID of the allow-ssh security group in your OpenStack project"
  type        = string
}

variable "sg_navidrome_id" {
  description = "ID of the navidrome service ports security group in your OpenStack project"
  type        = string
}
