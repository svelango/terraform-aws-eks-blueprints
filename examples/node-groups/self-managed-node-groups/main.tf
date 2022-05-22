provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
  }
}

data "aws_availability_zones" "available" {}

locals {
  tenant      = var.tenant      # AWS account name or unique id for tenant
  environment = var.environment # Environment area eg., preprod or prod
  zone        = var.zone        # Environment with in one sub_tenant or business unit
  region      = "us-west-2"

  vpc_cidr     = "10.0.0.0/16"
  vpc_name     = join("-", [local.tenant, local.environment, local.zone, "vpc"])
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name = join("-", [local.tenant, local.environment, local.zone, "eks"])

  terraform_version = "Terraform v1.0.1"
  policy_arn_prefix = "arn:aws:iam::aws:policy"
  ec2_principal     = "ec2.amazonaws.com"
}

module "aws_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}
#---------------------------------------------------------------
# Example to consume eks_blueprints module
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "../../.."

  tenant            = local.tenant
  environment       = local.environment
  zone              = local.zone
  terraform_version = local.terraform_version

  # EKS Cluster VPC and Subnet mandatory config
  vpc_id             = module.aws_vpc.vpc_id
  private_subnet_ids = module.aws_vpc.private_subnets

  # EKS CONTROL PLANE VARIABLES
  cluster_version = "1.21"

  self_managed_node_groups = {
    self_mg4 = {
      node_group_name    = "self_mg4"
      launch_template_os = "amazonlinux2eks"
      subnet_ids         = module.aws_vpc.private_subnets
    }
    self_mg5 = {
      node_group_name = "self_mg5" # Name is used to create a dedicated IAM role for each node group and adds to AWS-AUTH config map

      subnet_type            = "private"
      subnet_ids             = module.aws_vpc.private_subnets # Optional defaults to Private Subnet Ids used by EKS Control Plane
      create_launch_template = true
      launch_template_os     = "amazonlinux2eks" # amazonlinux2eks or bottlerocket or windows
      custom_ami_id          = ""                # Bring your own custom AMI generated by Packer/ImageBuilder/Puppet etc.

      create_iam_role           = false                                         # Changing `create_iam_role=false` to bring your own IAM Role
      iam_role_arn              = aws_iam_role.self_managed_ng.arn              # custom IAM role for aws-auth mapping; used when create_iam_role = false
      iam_instance_profile_name = aws_iam_instance_profile.self_managed_ng.name # IAM instance profile name for Launch templates; used when create_iam_role = false

      format_mount_nvme_disk = true
      public_ip              = false
      enable_monitoring      = false

      pre_userdata = <<-EOT
        yum install -y amazon-ssm-agent
        systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
      EOT

      post_userdata = "" # Optional config

      # --node-labels is used to apply Kubernetes Labels to Nodes
      # --register-with-taints used to apply taints to Nodes
      # e.g., kubelet_extra_args='--node-labels=WorkerType=SPOT,noderole=spark --register-with-taints=spot=true:NoSchedule --max-pods=58',
      kubelet_extra_args = "--node-labels=WorkerType=SPOT,noderole=spark --register-with-taints=test=true:NoSchedule --max-pods=20"

      # bootstrap_extra_args used only when you pass custom_ami_id. Allows you to change the Container Runtime for Nodes
      # e.g., bootstrap_extra_args="--use-max-pods false --container-runtime containerd"
      bootstrap_extra_args = "--use-max-pods false"

      block_device_mappings = [
        {
          device_name = "/dev/xvda" # mount point to /
          volume_type = "gp3"
          volume_size = 50
        },
        {
          device_name = "/dev/xvdf" # mount point to /local1 (it could be local2, depending upon the disks are attached during boot)
          volume_type = "gp3"
          volume_size = 80
          iops        = 3000
          throughput  = 125
        },
        {
          device_name = "/dev/xvdg" # mount point to /local2 (it could be local1, depending upon the disks are attached during boot)
          volume_type = "gp3"
          volume_size = 100
          iops        = 3000
          throughput  = 125
        }
      ]

      instance_type = "m5.large"
      desired_size  = 2
      max_size      = 10
      min_size      = 2
      capacity_type = "" # Optional Use this only for SPOT capacity as  capacity_type = "spot"

      k8s_labels = {
        Environment = "preprod"
        Zone        = "test"
        WorkerType  = "SELF_MANAGED_ON_DEMAND"
      }

      additional_tags = {
        ExtraTag    = "m5x-on-demand"
        Name        = "m5x-on-demand"
        subnet_type = "private"
      }
    }
  } # END OF SELF MANAGED NODE GROUPS
}

#---------------------------------------------------------------
# Custom IAM role for Self Managed Node Group
#---------------------------------------------------------------
data "aws_iam_policy_document" "self_managed_ng_assume_role_policy" {
  statement {
    sid = "EKSWorkerAssumeRole"

    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = [local.ec2_principal]
    }
  }
}

resource "aws_iam_role" "self_managed_ng" {
  name                  = "self-managed-node-role"
  description           = "EKS Managed Node group IAM Role"
  assume_role_policy    = data.aws_iam_policy_document.self_managed_ng_assume_role_policy.json
  path                  = "/"
  force_detach_policies = true
  managed_policy_arns = ["${local.policy_arn_prefix}/AmazonEKSWorkerNodePolicy",
    "${local.policy_arn_prefix}/AmazonEKS_CNI_Policy",
    "${local.policy_arn_prefix}/AmazonEC2ContainerRegistryReadOnly",
  "${local.policy_arn_prefix}/AmazonSSMManagedInstanceCore"]
}

resource "aws_iam_instance_profile" "self_managed_ng" {
  name = "self-managed-node-instance-profile"
  role = aws_iam_role.self_managed_ng.name
  path = "/"

  lifecycle {
    create_before_destroy = true
  }
}
