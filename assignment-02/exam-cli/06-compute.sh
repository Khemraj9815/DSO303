#!/usr/bin/env bash
# Phase 6 - Compute: ECR, ALB across 2 public subnets, ECS Fargate service (2 tasks, 1 per AZ) in private subnets
set -euo pipefail; source "$(dirname "$0")/00-config.sh"
TMP=$(mktemp -d)
# Placeholder image proves the infrastructure works; swap in your API image later (see README step).
IMAGE="${IMAGE:-public.ecr.aws/nginx/nginx:stable}"

step "6.1 ECR repository (for your API image later)"
save ECR_URI "$(aws ecr create-repository --repository-name "$P-api" --image-scanning-configuration scanOnPush=true \
  --query repository.repositoryUri --output text)"

step "6.2 ECS roles (execution role pulls images/writes logs; task role = app permissions)"
if [ -n "${LAB_ROLE_ARN:-}" ]; then
  save ECS_EXEC_ROLE_ARN "$LAB_ROLE_ARN"; save ECS_TASK_ROLE_ARN "$LAB_ROLE_ARN"; echo "  using Learner Lab LabRole"
else
  cat > "$TMP/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  save ECS_EXEC_ROLE_ARN "$(aws iam create-role --role-name "$P-ecs-exec-role" --assume-role-policy-document "file://$TMP/trust.json" --query Role.Arn --output text)"
  aws iam attach-role-policy --role-name "$P-ecs-exec-role" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  save ECS_TASK_ROLE_ARN "$(aws iam create-role --role-name "$P-ecs-task-role" --assume-role-policy-document "file://$TMP/trust.json" --query Role.Arn --output text)"
  cat > "$TMP/task-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:PutObject","s3:GetObject"],"Resource":"arn:aws:s3:::$SUB_BUCKET/submissions/*"},
 {"Effect":"Allow","Action":["sqs:SendMessage"],"Resource":"$QUEUE_ARN"},
 {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"$DB_SECRET_ARN"}]}
JSON
  aws iam put-role-policy --role-name "$P-ecs-task-role" --policy-name app-access --policy-document "file://$TMP/task-policy.json"
  echo "  waiting 15s for IAM to propagate..."; sleep 15
fi

step "6.3 Application Load Balancer in BOTH public subnets"
save ALB_ARN "$(aws elbv2 create-load-balancer --name "$P-alb" --type application --scheme internet-facing \
  --subnets "$PUB_A" "$PUB_B" --security-groups "$SG_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
save ALB_DNS "$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
save TG_ARN "$(aws elbv2 create-target-group --name "$P-api-tg" --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
  --target-type ip --health-check-path / --health-check-interval-seconds 15 --healthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
save LISTENER_ARN "$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" --query 'Listeners[0].ListenerArn' --output text)"

step "6.4 ECS cluster, log group, task definition"
save CLUSTER "$P-cluster"
aws ecs create-cluster --cluster-name "$CLUSTER" --settings name=containerInsights,value=enabled >/dev/null
aws logs create-log-group --log-group-name "/ecs/$P-api" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/ecs/$P-api" --retention-in-days 30
cat > "$TMP/taskdef.json" <<JSON
{"family":"$P-api","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"256","memory":"512",
 "executionRoleArn":"$ECS_EXEC_ROLE_ARN","taskRoleArn":"$ECS_TASK_ROLE_ARN",
 "containerDefinitions":[{"name":"api","image":"$IMAGE","essential":true,
   "portMappings":[{"containerPort":80,"protocol":"tcp"}],
   "environment":[{"name":"DB_HOST","value":"$DB_ENDPOINT"},{"name":"QUEUE_URL","value":"$QUEUE_URL"},
                  {"name":"SUBMISSIONS_BUCKET","value":"$SUB_BUCKET"},{"name":"USER_POOL_ID","value":"$USER_POOL_ID"}],
   "secrets":[{"name":"DB_SECRET","valueFrom":"$DB_SECRET_ARN"}],
   "logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/$P-api","awslogs-region":"$AWS_REGION","awslogs-stream-prefix":"api"}}}]}
JSON
save TASKDEF_ARN "$(aws ecs register-task-definition --cli-input-json "file://$TMP/taskdef.json" --query taskDefinition.taskDefinitionArn --output text)"

step "6.5 Fargate service: 2 tasks spread over private-a and private-b, behind the ALB"
aws ecs create-service --cluster "$CLUSTER" --service-name "$P-api" --task-definition "$TASKDEF_ARN" \
  --desired-count 2 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$SG_APP],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=api,containerPort=80" \
  --health-check-grace-period-seconds 60 >/dev/null
save SERVICE "$P-api"
echo "  waiting for the service to become stable (2-5 min)..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

step "6.6 Auto scaling: min 2 / max 10, target 60% CPU"
aws application-autoscaling register-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/$CLUSTER/$SERVICE" --min-capacity 2 --max-capacity 10
aws application-autoscaling put-scaling-policy --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/$CLUSTER/$SERVICE" --policy-name cpu-60 --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration \
  '{"TargetValue":60,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},"ScaleInCooldown":120,"ScaleOutCooldown":60}' >/dev/null

step "6.7 Check: healthy targets (one IP per AZ)"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State]' --output table
echo; echo "Phase 6 done. (The ALB only accepts CloudFront traffic, so test it through CloudFront in phase 7.)"
