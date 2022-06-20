provider "aws" {
  region = local.aws_region
}

locals {
  olexiyb_public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEqrfgMhpeWHi9Hwr5zOq7dOJiU9+OM0IHuyHEbJYJsw olexiyb"
  cluster_name = "rancher"
  aws_region   = "us-east-1"

  tags = {
    "terraform" = "true",
    "env"       = "cloud-enabled",
  }
}

data "aws_ami" "rhel8" {
  most_recent = true
  owners      = ["309956199498"] # owner is specific to aws gov cloud

  filter {
    name   = "name"
    values = ["RHEL_HA-8*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # owner is specific to aws gov cloud

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
# Key Pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_pem" {
  filename        = "${local.cluster_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

#
# Network
#
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "rke2-${local.cluster_name}"
  cidr = "10.88.0.0/16"

  azs             = ["${local.aws_region}a", "${local.aws_region}b", "${local.aws_region}c"]
  public_subnets  = ["10.88.1.0/24", "10.88.2.0/24", "10.88.3.0/24"]
  private_subnets = ["10.88.101.0/24", "10.88.102.0/24", "10.88.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_vpn_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Add in required tags for proper AWS CCM integration
  public_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                            = "1"
  }, local.tags)

  private_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"                   = "1"
  }, local.tags)

  tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
  }, local.tags)
}

#
# Server
#
module "rke2" {
  source = "../.."

  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnets      = module.vpc.public_subnets # Note: Public subnets used for demo purposes, this is not recommended in production

  ami                   = data.aws_ami.ubuntu.image_id # Note: Multi OS is primarily for example purposes
  ssh_authorized_keys   = [tls_private_key.ssh.public_key_openssh,local.olexiyb_public]
  instance_type         = "t3.medium"
  controlplane_internal = false # Note this defaults to best practice of true, but is explicitly set to public for demo purposes
  servers               = 2

  # Enable AWS Cloud Controller Manager
  enable_ccm = true

  rke2_config = <<-EOT
cni:
  - cilium
node-label:
  - "name=server"
  - "os=ubuntu"
EOT

  tags = local.tags
}

#
# Generic agent pool
#
module "agents" {
  source = "../../modules/agent-nodepool"

  name    = "generic"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets # Note: Public subnets used for demo purposes, this is not recommended in production

  ami                 = data.aws_ami.ubuntu.image_id # Note: Multi OS is primarily for example purposes
  ssh_authorized_keys = [tls_private_key.ssh.public_key_openssh,local.olexiyb_public]
  spot                = true
  asg                 = { min : 0, max : 10, desired : 0 }
  instance_type       = "t3a.large"

  # Enable AWS Cloud Controller Manager and Cluster Autoscaler
  enable_ccm        = true
  enable_autoscaler = true

  rke2_config = <<-EOT
node-label:
  - "name=agent"
  - "os=ubuntu"
EOT

  cluster_data = module.rke2.cluster_data

  tags = local.tags
}

# For demonstration only, lock down ssh access in production
resource "aws_security_group_rule" "quickstart_ssh" {
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = module.rke2.cluster_data.cluster_sg
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Generic outputs as examples
output "rke2" {
  value = module.rke2
}

# Example method of fetching kubeconfig from state store, requires aws cli and bash locally
resource "null_resource" "kubeconfig" {
  depends_on = [module.rke2]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "aws s3 cp ${module.rke2.kubeconfig_path} rke2.yaml"
  }
}
