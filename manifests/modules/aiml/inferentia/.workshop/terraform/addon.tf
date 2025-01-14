data "aws_subnets" "private" {
  tags = {
    created-by = "eks-workshop-v2"
    env        = local.addon_context.eks_cluster_id
  }

  filter {
    name   = "tag:Name"
    values = ["*Private*"]
  }
}

resource "aws_s3_bucket" "inference" {
  bucket_prefix = "eksworkshop-inference"
  force_destroy = true

  tags = local.tags
}


module "iam_assumable_role_inference" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "~> v5.5.0"
  create_role                   = true
  role_name                     = "${local.addon_context.eks_cluster_id}-inference"
  provider_url                  = local.addon_context.eks_oidc_issuer_url
  role_policy_arns              = [aws_iam_policy.inference.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:aiml:inference"]

  tags = local.tags
}

resource "aws_iam_policy" "inference" {
  name        = "${local.addon_context.eks_cluster_id}-inference"
  path        = "/"
  description = "IAM policy for the inferenct workload"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${aws_s3_bucket.inference.id}",
        "arn:aws:s3:::${aws_s3_bucket.inference.id}/*"
      ]
    }
  ]
}
EOF
}

module "karpenter" {
  source        = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.25.0//modules/kubernetes-addons/karpenter"
  addon_context = merge(local.addon_context, { default_repository = local.amazon_container_image_registry_uris[data.aws_region.current.name] })

  node_iam_instance_profile = aws_iam_instance_profile.karpenter_node.name

  helm_config = {
    set = [{
      name  = "replicas"
      value = "1"
    }]
  }
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.addon_context.eks_cluster_id}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role" "karpenter_node" {
  name = "${local.addon_context.eks_cluster_id}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  managed_policy_arns = [
    "arn:${local.addon_context.aws_partition_id}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.addon_context.aws_partition_id}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.addon_context.aws_partition_id}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.addon_context.aws_partition_id}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]

  tags = local.tags
}

data "http" "neuron_device_plugin_rbac_manifest" {
  url = "https://raw.githubusercontent.com/aws-neuron/aws-neuron-sdk/v2.6.0/src/k8/k8s-neuron-device-plugin-rbac.yml"
}

data "http" "neuron_device_plugin_manifest" {
  url = "https://raw.githubusercontent.com/aws-neuron/aws-neuron-sdk/v2.6.0/src/k8/k8s-neuron-device-plugin.yml"
}

data "kubectl_file_documents" "neuron_device_plugin_rbac_doc" {
  content = data.http.neuron_device_plugin_rbac_manifest.response_body
}

data "kubectl_file_documents" "neuron_device_plugin_doc" {
  content = data.http.neuron_device_plugin_manifest.response_body
}

resource "kubectl_manifest" "neuron_device_plugin_rbac" {
  for_each  = data.kubectl_file_documents.neuron_device_plugin_rbac_doc.manifests
  yaml_body = each.value
}

resource "kubectl_manifest" "neuron_device_plugin" {
  for_each  = data.kubectl_file_documents.neuron_device_plugin_doc.manifests
  yaml_body = each.value
}

output "environment" {
  value = <<EOF
export AIML_NEURON_ROLE_ARN=${module.iam_assumable_role_inference.iam_role_arn}
export AIML_NEURON_BUCKET_NAME=${resource.aws_s3_bucket.inference.id}
export AIML_DL_IMAGE=763104351884.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/pytorch-inference-neuron:1.13.1-neuron-py310-sdk2.12.0-ubuntu20.04
export AIML_SUBNETS=${data.aws_subnets.private.ids[0]},${data.aws_subnets.private.ids[1]},${data.aws_subnets.private.ids[2]}
export KARPENTER_NODE_ROLE="${aws_iam_role.karpenter_node.arn}"
EOF
}
