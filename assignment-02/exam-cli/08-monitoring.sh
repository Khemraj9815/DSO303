#!/usr/bin/env bash
# Phase 8 - Monitoring: CloudWatch alarms on the things that break an exam
set -euo pipefail; source "$(dirname "$0")/00-config.sh"
LB_DIM="${ALB_ARN#*:loadbalancer/}"
TG_DIM="${TG_ARN##*:}"

alarm() { # name namespace metric stat threshold operator dims...
  local name=$1 ns=$2 metric=$3 stat=$4 thr=$5 op=$6; shift 6
  aws cloudwatch put-metric-alarm --alarm-name "$P-$name" --namespace "$ns" --metric-name "$metric" \
    --statistic "$stat" --period 60 --evaluation-periods 3 --threshold "$thr" --comparison-operator "$op" \
    --treat-missing-data notBreaching --dimensions "$@"
  echo "  alarm: $P-$name"
}
step "8.1 Alarms"
alarm alb-5xx        AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum 10 GreaterThanThreshold Name=LoadBalancer,Value="$LB_DIM"
alarm alb-unhealthy  AWS/ApplicationELB UnHealthyHostCount Maximum 0 GreaterThanThreshold Name=LoadBalancer,Value="$LB_DIM" Name=TargetGroup,Value="$TG_DIM"
alarm ecs-cpu-high   AWS/ECS CPUUtilization Average 80 GreaterThanThreshold Name=ClusterName,Value="$CLUSTER" Name=ServiceName,Value="$SERVICE"
alarm rds-cpu-high   AWS/RDS CPUUtilization Average 80 GreaterThanThreshold Name=DBInstanceIdentifier,Value="$DB_ID"
alarm rds-low-storage AWS/RDS FreeStorageSpace Minimum 2000000000 LessThanThreshold Name=DBInstanceIdentifier,Value="$DB_ID"
alarm dlq-not-empty  AWS/SQS ApproximateNumberOfMessagesVisible Maximum 0 GreaterThanThreshold Name=QueueName,Value="$P-jobs-dlq"
aws cloudwatch describe-alarms --alarm-name-prefix "$P-" --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
echo; echo "Phase 8 done."
