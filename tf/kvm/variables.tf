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
  description = "Blazar reservation ID from KVM@TACC lease — used as flavor_id for flavor:instance reservations"
  type        = string
}


variable "nodes" {
  type = map(string)
  default = {
    "node1" = "192.168.1.11"
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
