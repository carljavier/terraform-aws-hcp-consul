locals {
  vpc_region = "{{ .VPCRegion }}"
  hvn_region = "{{ .HVNRegion }}"
  cluster_id = "{{ .ClusterID }}"
  hvn_id     = "{{ .ClusterID }}-hvn"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.43"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = ">= 0.18.0"
    }
  }

}

provider "aws" {
  region = local.vpc_region
}

provider "consul" {
  address    = hcp_consul_cluster.main.consul_public_endpoint_url
  datacenter = hcp_consul_cluster.main.datacenter
  token      = hcp_consul_cluster_root_token.token.secret_id
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.10.0"

  name                 = "${local.cluster_id}-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets       = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_dns_hostnames = true
  enable_nat_gateway   = true
  single_nat_gateway   = true
}

resource "hcp_hvn" "main" {
  hvn_id         = local.hvn_id
  cloud_provider = "aws"
  region         = local.hvn_region
  cidr_block     = "172.25.32.0/20"
}

module "aws_hcp_consul" {
  source  = "hashicorp/hcp-consul/aws"
  version = "~> 0.6.1"

  hvn    = hcp_hvn.main
  vpc_id = module.vpc.vpc_id
  subnet_ids = concat(
    module.vpc.private_subnets,
    module.vpc.public_subnets,
  )
  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.public_route_table_ids,
  )
}

resource "hcp_consul_cluster" "main" {
  cluster_id      = local.cluster_id
  hvn_id          = hcp_hvn.main.hvn_id
  public_endpoint = true
  tier            = "development"
}

resource "consul_config_entry" "service_intentions" {
  name = "*"
  kind = "service-intentions"

  config_json = jsonencode({
    Sources = [
      {
        Action     = "allow"
        Name       = "*"
        Precedence = 9
        Type       = "consul"
      },
    ]
  })
}

resource "hcp_consul_cluster_root_token" "token" {
  cluster_id = hcp_consul_cluster.main.id
}

module "aws_ecs_cluster" {
  source  = "hashicorp/hcp-consul/aws//modules/hcp-ecs-client"
  version = "~> 0.6.1"

  private_subnet_ids       = module.vpc.private_subnets
  public_subnet_ids        = module.vpc.public_subnets
  vpc_id                   = module.vpc.vpc_id
  security_group_id        = module.aws_hcp_consul.security_group_id
  allowed_ssh_cidr_blocks  = ["0.0.0.0/0"]
  allowed_http_cidr_blocks = ["0.0.0.0/0"]
  client_config_file       = hcp_consul_cluster.main.consul_config_file
  client_ca_file           = hcp_consul_cluster.main.consul_ca_file
  client_gossip_key        = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["encrypt"]
  client_retry_join        = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["retry_join"]
  region                   = local.vpc_region
  root_token               = hcp_consul_cluster_root_token.token.secret_id
  consul_url               = hcp_consul_cluster.main.consul_private_endpoint_url
  consul_version           = substr(hcp_consul_cluster.main.consul_version, 1, -1)
  datacenter               = hcp_consul_cluster.main.datacenter
}

resource "consul_config_entry" "service_intentions_db" {
  name = "product-db"
  kind = "service-intentions"

  config_json = jsonencode({
    Sources = [
      {
        Action     = "allow"
        Name       = "product-api"
        Precedence = 9
        Type       = "consul"
      },
    ]
  })
}

resource "consul_config_entry" "service_intentions_product" {
  name = "product-api"
  kind = "service-intentions"

  config_json = jsonencode({
    Sources = [
      {
        Action     = "allow"
        Name       = "product-public-api"
        Precedence = 9
        Type       = "consul"
      },
    ]
  })
}

resource "consul_config_entry" "service_intentions_payment" {
  name = "payment-api"
  kind = "service-intentions"

  config_json = jsonencode({
    Sources = [
      {
        Action     = "allow"
        Name       = "product-public-api"
        Precedence = 9
        Type       = "consul"
      },
    ]
  })
}

resource "consul_config_entry" "service_intentions_public_api" {
  name = "product-public-api"
  kind = "service-intentions"

  config_json = jsonencode({
    Sources = [
      {
        Action     = "allow"
        Name       = "frontend"
        Precedence = 9
        Type       = "consul"
      },
    ]
  })
}

output "consul_root_token" {
  value     = hcp_consul_cluster_root_token.token.secret_id
  sensitive = true
}

output "consul_url" {
  value = hcp_consul_cluster.main.public_endpoint ? (
    hcp_consul_cluster.main.consul_public_endpoint_url
    ) : (
    hcp_consul_cluster.main.consul_private_endpoint_url
  )
}

output "hashicups_url" {
  value = "http://${module.aws_ecs_cluster.hashicups_url}"
}

output "next_steps" {
  value = "Hashicups Application will be ready in ~2 minutes. Use 'terraform output consul_root_token' to retrieve the root token."
}
