
resource "openstack_networking_network_v2" "private_net" {
  name                  = "private-net-mlops-${var.suffix}"
  port_security_enabled = false
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name       = "private-subnet-mlops-${var.suffix}"
  network_id = openstack_networking_network_v2.private_net.id
  cidr       = "192.168.1.0/24"
  no_gateway = true
}

# CPU nodes (control-plane + worker nodes)
resource "openstack_networking_port_v2" "private_net_ports" {
  for_each              = var.nodes
  name                  = "port-${each.key}-mlops-${var.suffix}"
  network_id            = openstack_networking_network_v2.private_net.id
  port_security_enabled = false

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = each.value
  }
}

resource "openstack_networking_port_v2" "public_net_ports" {
  for_each   = var.nodes
  name       = "public_net-${each.key}-mlops-${var.suffix}"
  network_id = data.openstack_networking_network_v2.public_net.id

  security_group_ids = [
    var.sg_default_id,
    var.sg_ssh_id,
    var.sg_navidrome_id,
  ]
}

resource "openstack_compute_instance_v2" "nodes" {
  for_each = var.nodes

  name       = "${each.key}-mlops-${var.suffix}"
  image_name = "CC-Ubuntu24.04"
  flavor_id  = var.reservation_id
  key_pair   = var.key

  network {
    port = openstack_networking_port_v2.public_net_ports[each.key].id
  }

  network {
    port = openstack_networking_port_v2.private_net_ports[each.key].id
  }

  user_data = <<-EOF
    #! /bin/bash
    sudo echo "127.0.1.1 ${each.key}-mlops-${var.suffix}" >> /etc/hosts
    su cc -c /usr/local/bin/cc-load-public-keys
  EOF
}

# GPU nodes (optional, from separate bare-metal reservation)
resource "openstack_networking_port_v2" "gpu_private_net_ports" {
  for_each              = var.gpu_reservation_id != "" ? var.gpu_nodes : {}
  name                  = "port-${each.key}-mlops-${var.suffix}"
  network_id            = openstack_networking_network_v2.private_net.id
  port_security_enabled = false

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = each.value
  }
}

resource "openstack_networking_port_v2" "gpu_public_net_ports" {
  for_each   = var.gpu_reservation_id != "" ? var.gpu_nodes : {}
  name       = "public_net-${each.key}-mlops-${var.suffix}"
  network_id = data.openstack_networking_network_v2.public_net.id

  security_group_ids = [
    var.sg_default_id,
    var.sg_ssh_id,
    var.sg_navidrome_id,
  ]
}

resource "openstack_compute_instance_v2" "gpu_nodes" {
  for_each = var.gpu_reservation_id != "" ? var.gpu_nodes : {}

  name       = "${each.key}-mlops-${var.suffix}"
  image_name = "CC-Ubuntu24.04"
  flavor_id  = var.gpu_reservation_id
  key_pair   = var.key

  network {
    port = openstack_networking_port_v2.gpu_public_net_ports[each.key].id
  }

  network {
    port = openstack_networking_port_v2.gpu_private_net_ports[each.key].id
  }

  user_data = <<-EOF
    #! /bin/bash
    sudo echo "127.0.1.1 ${each.key}-mlops-${var.suffix}" >> /etc/hosts
    su cc -c /usr/local/bin/cc-load-public-keys
  EOF
}

# Open required ports on navidrome-sg-proj05 (existing shared security group)
locals {
  navidrome_sg_id = var.sg_navidrome_id
  service_ports   = [4533, 8000, 9000, 9001, 3000, 9090, 9093]  # Added Grafana (3000), Prometheus (9090), Alertmanager (9093)
}

resource "openstack_networking_secgroup_rule_v2" "navidrome_ports" {
  for_each          = toset([for p in local.service_ports : tostring(p)])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = local.navidrome_sg_id

  lifecycle {
    ignore_changes = all  # rules may already exist from manual setup
  }
}

resource "openstack_networking_floatingip_v2" "floating_ip" {
  pool        = "public"
  description = "Navidrome IP for ${var.suffix}"
  port_id     = openstack_networking_port_v2.public_net_ports["node1"].id
}
