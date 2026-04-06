#!/usr/bin/env bash
# EKS managed node group join troubleshooting (AWS CLI).
# Usage: set CLUSTER, REGION, NODEGROUP below (or export before running), then:
#   bash eks-node-join-troubleshoot.sh

set -euo pipefail

CLUSTER="${CLUSTER:-nvidiagpu}"
REGION="${REGION:-us-east-1}"
NODEGROUP="${NODEGROUP:-${CLUSTER}-t4g-medium}"

echo "=== 1) Node group status and health (EKS) ==="
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --region "$REGION" \
  --query 'nodegroup.{status:status,health:health,scalingConfig:scalingConfig,subnets:subnets,nodeRole:nodeRole,releaseVersion:releaseVersion,version:version}' \
  --output yaml 2>&1 || echo "(If NotFound, fix NODEGROUP name: aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION)"

echo
echo "=== 2) Cluster API endpoint and network (EKS) ==="
aws eks describe-cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --query 'cluster.{version:version,endpoint:endpoint,status:status,accessConfig:accessConfig,resourcesVpcConfig:resourcesVpcConfig}' \
  --output yaml

echo
echo "=== 3) Auto Scaling activities (recent failures) ==="
ASG_NAME=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --region "$REGION" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' \
  --output text 2>/dev/null || echo "")
if [[ -n "$ASG_NAME" && "$ASG_NAME" != "None" ]]; then
  aws autoscaling describe-scaling-activities \
    --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --max-items 10 \
    --query 'Activities[*].[StartTime,StatusCode,Description,Cause]' \
    --output table
else
  echo "No ASG name yet (node group may still be CREATING or name wrong)."
fi

echo
echo "=== 4) EC2 instances tagged for this cluster ==="
aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone,PrivateIp:PrivateIpAddress,Launch:LaunchTime}' \
  --output table 2>&1 || true

echo
echo "=== 5) Node IAM role and access entry (if cluster uses API access entries) ==="
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --region "$REGION" \
  --query 'nodegroup.nodeRole' \
  --output text 2>/dev/null || echo "")
if [[ -n "$NODE_ROLE" && "$NODE_ROLE" != "None" ]]; then
  echo "Node role: $NODE_ROLE"
  aws eks describe-access-entry \
    --cluster-name "$CLUSTER" \
    --region "$REGION" \
    --principal-arn "$NODE_ROLE" \
    --output yaml 2>&1 || echo "(No access entry or not authorized to describe — check IAM / auth mode.)"
else
  echo "Could not read nodeRole from node group."
fi

echo
echo "=== 6) VPC interface endpoints in the cluster VPC (spot-check) ==="
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)
echo "VPC: $VPC_ID"
aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].{Id:VpcEndpointId,Type:VpcEndpointType,Service:ServiceName,State:State}' \
  --output table 2>&1 | head -40

echo
echo "=== Next steps (on the failing instance) ==="
echo "SSM/SSH to the node, then:"
echo "  sudo tail -200 /var/log/cloud-init-output.log"
echo "  sudo journalctl -u kubelet -b --no-pager | tail -200"
echo "Look for: timeout, ECR, S3, sts, x509, 403, ImagePull, sandbox."
echo
echo "Edit CLUSTER / REGION / NODEGROUP at top of this script if needed."
