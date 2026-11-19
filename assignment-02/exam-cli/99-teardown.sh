#!/usr/bin/env bash
# Delete EVERYTHING in reverse order. Safe to re-run: failures on already-deleted items are ignored.
set -uo pipefail; source "$(dirname "$0")/00-config.sh"
q() { "$@" >/dev/null 2>&1 || true; }

step "Backup"
q aws backup delete-backup-selection --backup-plan-id "${BACKUP_PLAN_ID:-x}" --selection-id "${BACKUP_SELECTION_ID:-x}"
q aws backup delete-backup-plan --backup-plan-id "${BACKUP_PLAN_ID:-x}"
for rp in $(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$P-vault" --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null); do
  q aws backup delete-recovery-point --backup-vault-name "$P-vault" --recovery-point-arn "$rp"; done
q aws backup delete-backup-vault --backup-vault-name "$P-vault"

step "Alarms"
q aws cloudwatch delete-alarms --alarm-names $(aws cloudwatch describe-alarms --alarm-name-prefix "$P-" --query 'MetricAlarms[].AlarmName' --output text)

step "CloudFront (disable -> wait -> delete; takes several minutes) + WAF + OAC"
if [ -n "${CF_ID:-}" ]; then
  aws cloudfront get-distribution-config --id "$CF_ID" > /tmp/cf.json 2>/dev/null && {
    ETAG=$(python3 -c "import json;print(json.load(open('/tmp/cf.json'))['ETag'])")
    python3 -c "import json;d=json.load(open('/tmp/cf.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('/tmp/cf-off.json','w'))"
    q aws cloudfront update-distribution --id "$CF_ID" --if-match "$ETAG" --distribution-config file:///tmp/cf-off.json
    echo "  waiting for CloudFront to disable..."; aws cloudfront wait distribution-deployed --id "$CF_ID"
    ETAG=$(aws cloudfront get-distribution --id "$CF_ID" --query ETag --output text)
    q aws cloudfront delete-distribution --id "$CF_ID" --if-match "$ETAG"; }
fi
[ -n "${WAF_ID:-}" ] && q aws wafv2 delete-web-acl --region us-east-1 --scope CLOUDFRONT --name "$P-waf" --id "$WAF_ID" \
   --lock-token "$(aws wafv2 get-web-acl --region us-east-1 --scope CLOUDFRONT --name "$P-waf" --id "$WAF_ID" --query LockToken --output text)"
[ -n "${OAC_ID:-}" ] && q aws cloudfront delete-origin-access-control --id "$OAC_ID" \
   --if-match "$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query ETag --output text)"

step "API Lambda (phase 11)"
q aws lambda delete-function --function-name "$P-api"
q aws logs delete-log-group --log-group-name "/aws/lambda/$P-api"

step "ECS, ALB, ECR"
q aws application-autoscaling deregister-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id "service/$P-cluster/$P-api"
q aws ecs update-service --cluster "$P-cluster" --service "$P-api" --desired-count 0
q aws ecs delete-service --cluster "$P-cluster" --service "$P-api" --force
aws ecs wait services-inactive --cluster "$P-cluster" --services "$P-api" 2>/dev/null || true
for td in $(aws ecs list-task-definitions --family-prefix "$P-api" --query taskDefinitionArns --output text 2>/dev/null); do q aws ecs deregister-task-definition --task-definition "$td"; done
q aws ecs delete-cluster --cluster "$P-cluster"
[ -n "${ALB_ARN:-}" ] && { q aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"; aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true; }
[ -n "${TG_ARN:-}" ] && q aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
[ -n "${LAMBDA_TG_ARN:-}" ] && q aws elbv2 delete-target-group --target-group-arn "$LAMBDA_TG_ARN"
q aws ecr delete-repository --repository-name "$P-api" --force
q aws logs delete-log-group --log-group-name "/ecs/$P-api"

step "Lambda, SQS, SES"
[ -n "${ESM_UUID:-}" ] && q aws lambda delete-event-source-mapping --uuid "$ESM_UUID"
q aws lambda delete-function --function-name "$P-worker"
q aws logs delete-log-group --log-group-name "/aws/lambda/$P-worker"
[ -n "${QUEUE_URL:-}" ] && q aws sqs delete-queue --queue-url "$QUEUE_URL"
[ -n "${DLQ_URL:-}" ] && q aws sqs delete-queue --queue-url "$DLQ_URL"
for e in $(printf "%s\n%s\n" "$SES_FROM_EMAIL" "$TUTOR_EMAIL" | sort -u); do q aws ses delete-identity --identity "$e"; done

step "Cognito"
[ -n "${USER_POOL_ID:-}" ] && q aws cognito-idp delete-user-pool --user-pool-id "$USER_POOL_ID"

step "S3 buckets (delete all object versions first)"
empty_and_delete() {
  local b=$1; aws s3api head-bucket --bucket "$b" 2>/dev/null || return 0
  q aws s3api put-bucket-notification-configuration --bucket "$b" --notification-configuration '{}'
  while :; do
    v=$(aws s3api list-object-versions --bucket "$b" --max-items 500 \
        --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json)
    echo "$v" | grep -q '"Key"' || break
    q aws s3api delete-objects --bucket "$b" --delete "$v"
  done
  q aws s3api delete-bucket --bucket "$b"; echo "  deleted $b"
}
empty_and_delete "$P-submissions-$ACCOUNT_ID"
empty_and_delete "$P-frontend-$ACCOUNT_ID"

step "RDS (10-15 min)"
q aws rds delete-db-instance --db-instance-identifier "$P-db" --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier "$P-db" 2>/dev/null || true
q aws rds delete-db-subnet-group --db-subnet-group-name "$P-db-subnets"

step "IAM roles (only exist outside Learner Lab)"
for r in "$P-api-lambda-role" "$P-worker-role" "$P-ecs-exec-role" "$P-ecs-task-role" "$P-backup-role"; do
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || continue
  for a in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do q aws iam detach-role-policy --role-name "$r" --policy-arn "$a"; done
  for i in $(aws iam list-role-policies --role-name "$r" --query PolicyNames --output text); do q aws iam delete-role-policy --role-name "$r" --policy-name "$i"; done
  q aws iam delete-role --role-name "$r"; echo "  deleted $r"
done

step "Network"
[ -n "${NAT_A:-}" ] && q aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_A"
[ -n "${NAT_B:-}" ] && q aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_B"
[ -n "${NAT_A:-}" ] && aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_A" "$NAT_B" 2>/dev/null || true
[ -n "${EIP_A:-}" ] && q aws ec2 release-address --allocation-id "$EIP_A"
[ -n "${EIP_B:-}" ] && q aws ec2 release-address --allocation-id "$EIP_B"
echo "  waiting for Lambda/ALB network interfaces to be released (can take up to 20 min after deleting a VPC Lambda)..."
for i in $(seq 1 40); do
  n=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="${VPC_ID:-none}" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
  [ "$n" = "0" ] && break; echo "    $n interface(s) left..."; sleep 30
done
for sg in "${SG_DB:-}" "${SG_APP:-}" "${SG_ALB:-}"; do [ -n "$sg" ] && q aws ec2 delete-security-group --group-id "$sg"; done
for s in "${PUB_A:-}" "${PUB_B:-}" "${PRIV_A:-}" "${PRIV_B:-}"; do [ -n "$s" ] && q aws ec2 delete-subnet --subnet-id "$s"; done
for r in "${RT_PUB:-}" "${RT_PRIV_A:-}" "${RT_PRIV_B:-}"; do [ -n "$r" ] && q aws ec2 delete-route-table --route-table-id "$r"; done
[ -n "${IGW_ID:-}" ] && { q aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"; q aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"; }
[ -n "${VPC_ID:-}" ] && { aws ec2 delete-vpc --vpc-id "$VPC_ID" && echo "  VPC deleted" || echo "  VPC still has dependencies - wait a minute and re-run this script"; }
mv "$IDS" "$IDS.deleted-$(date +%s)" 2>/dev/null || true
echo; echo "Teardown finished."
