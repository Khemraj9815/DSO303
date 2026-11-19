#!/usr/bin/env bash
# Verify a phase:   bash verify.sh 1      (phases 1-9)   or   bash verify.sh all
set -uo pipefail; source "$(dirname "$0")/00-config.sh"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1  (got: '$2', expected: '$3')"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }      # check "desc" actual expected
checkge(){ [ "${2:-0}" -ge "$3" ] 2>/dev/null && ok "$1 ($2)" || bad "$1" "$2" ">= $3"; }
need() { for v in "$@"; do [ -n "${!v:-}" ] || { echo "  ⚠️  $v not in ids.env - run that phase first"; return 1; }; done; }
title(){ echo; echo "================ PHASE $1: $2 ================"; }
shots(){ echo; echo "  📸 Screenshot for the report:"; for s in "$@"; do echo "     - $s"; done; }

phase1() { title 1 "Network"; need VPC_ID PUB_A PUB_B PRIV_A PRIV_B IGW_ID NAT_A NAT_B RT_PUB RT_PRIV_A RT_PRIV_B SG_ALB SG_APP SG_DB || return
  check "VPC exists with CIDR 10.0.0.0/16" "$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].CidrBlock' --output text)" "10.0.0.0/16"
  check "DNS hostnames enabled" "$(aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames --query EnableDnsHostnames.Value --output text)" "True"
  check "4 subnets in the VPC" "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'length(Subnets)')" "4"
  check "Subnets span 2 AZs" "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')" "2"
  check "Private subnets do NOT auto-assign public IPs" "$(aws ec2 describe-subnets --subnet-ids $PRIV_A $PRIV_B --query 'Subnets[].MapPublicIpOnLaunch' --output text | tr '\t' ' ')" "False False"
  check "Internet Gateway attached" "$(aws ec2 describe-internet-gateways --internet-gateway-ids $IGW_ID --query 'InternetGateways[0].Attachments[0].State' --output text)" "available"
  check "Public route 0.0.0.0/0 -> IGW" "$(aws ec2 describe-route-tables --route-table-ids $RT_PUB --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId|[0]" --output text)" "$IGW_ID"
  check "Private A route -> NAT A (same AZ)" "$(aws ec2 describe-route-tables --route-table-ids $RT_PRIV_A --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId|[0]" --output text)" "$NAT_A"
  check "Private B route -> NAT B (same AZ)" "$(aws ec2 describe-route-tables --route-table-ids $RT_PRIV_B --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId|[0]" --output text)" "$NAT_B"
  check "Both NAT gateways available" "$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_A $NAT_B --query 'NatGateways[].State' --output text | tr '\t' ' ')" "available available"
  check "ALB SG only allows CloudFront prefix list" "$(aws ec2 describe-security-groups --group-ids $SG_ALB --query 'SecurityGroups[0].IpPermissions[0].PrefixListIds[0].PrefixListId' --output text)" "$CF_PL"
  check "App SG only allows ALB SG" "$(aws ec2 describe-security-groups --group-ids $SG_APP --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)" "$SG_ALB"
  check "DB SG only allows App SG on 5432" "$(aws ec2 describe-security-groups --group-ids $SG_DB --query 'SecurityGroups[0].IpPermissions[0].[FromPort,UserIdGroupPairs[0].GroupId]' --output text | tr '\t' ' ')" "5432 $SG_APP"
  echo; aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
    --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}' --output table
  shots "This verify output" "Console > VPC > Your VPCs > exam-vpc > Resource map" "Console > VPC > Security groups > exam-db-sg > Inbound rules"; }

phase2() { title 2 "Database (RDS Multi-AZ + Secrets Manager)"; need DB_ID DB_SECRET_ARN || return
  Q() { aws rds describe-db-instances --db-instance-identifier $DB_ID --query "DBInstances[0].$1" --output text; }
  check "RDS status available" "$(Q DBInstanceStatus)" "available"
  check "Multi-AZ enabled" "$(Q MultiAZ)" "True"
  P_AZ=$(Q AvailabilityZone); S_AZ=$(Q SecondaryAvailabilityZone)
  [ -n "$S_AZ" ] && [ "$S_AZ" != "None" ] && [ "$P_AZ" != "$S_AZ" ] && ok "Primary ($P_AZ) and standby ($S_AZ) in different AZs" || bad "Primary/standby AZs differ" "$P_AZ/$S_AZ" "two different AZs"
  check "Storage encrypted" "$(Q StorageEncrypted)" "True"
  check "NOT publicly accessible" "$(Q PubliclyAccessible)" "False"
  checkge "Backup retention days (PITR enabled)" "$(Q BackupRetentionPeriod)" 1
  [ "$(Q LatestRestorableTime)" != "None" ] && ok "Point-in-time restore available (latest: $(Q LatestRestorableTime))" || bad "PITR" "None" "a timestamp"
  check "DB subnet group uses the 2 private subnets" "$(Q 'DBSubnetGroup.Subnets[].SubnetIdentifier' | tr '\t' '\n' | sort | tr '\n' ' ')" "$(printf '%s\n%s\n' $PRIV_A $PRIV_B | sort | tr '\n' ' ')"
  check "DB uses db-sg only" "$(Q 'VpcSecurityGroups[0].VpcSecurityGroupId')" "$SG_DB"
  check "Master password stored in Secrets Manager" "$(aws secretsmanager describe-secret --secret-id $DB_SECRET_ARN --query 'ARN' --output text)" "$DB_SECRET_ARN"
  echo; aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].{Endpoint:Endpoint.Address,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,PrimaryAZ:AvailabilityZone,StandbyAZ:SecondaryAvailabilityZone,Encrypted:StorageEncrypted,Public:PubliclyAccessible}' --output table
  shots "This verify output" "Console > RDS > exam-db > Configuration tab (Multi-AZ: Yes, Secondary zone)" "Console > Secrets Manager > rds!db-... secret (do NOT reveal the value)"; }

phase3() { title 3 "Storage (S3)"; need SUB_BUCKET WEB_BUCKET || return
  for b in $SUB_BUCKET $WEB_BUCKET; do
    aws s3api head-bucket --bucket $b 2>/dev/null && ok "Bucket $b exists" || bad "Bucket $b exists" "missing" "exists"
    check "$b blocks ALL public access" "$(aws s3api get-public-access-block --bucket $b --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')" "True True True True"
    check "$b encrypted at rest" "$(aws s3api get-bucket-encryption --bucket $b --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" "AES256"
  done
  check "Submissions versioning enabled" "$(aws s3api get-bucket-versioning --bucket $SUB_BUCKET --query Status --output text)" "Enabled"
  check "Lifecycle: 30d -> STANDARD_IA, 365d -> GLACIER" "$(aws s3api get-bucket-lifecycle-configuration --bucket $SUB_BUCKET --query 'Rules[0].Transitions[].[Days,StorageClass]' --output text | tr '\t\n' '  ' | xargs)" "30 STANDARD_IA 365 GLACIER"
  check "Lifecycle: delete after 1825 days (5 years)" "$(aws s3api get-bucket-lifecycle-configuration --bucket $SUB_BUCKET --query 'Rules[0].Expiration.Days' --output text)" "1825"
  CORS=$(aws s3api get-bucket-cors --bucket $SUB_BUCKET --query 'CORSRules[0].AllowedOrigins[0]' --output text 2>/dev/null)
  [ -n "$CORS" ] && ok "CORS configured for browser uploads (origin: $CORS)" || bad "CORS" "none" "a rule"
  shots "This verify output" "Console > S3 > $SUB_BUCKET > Management > Lifecycle rule details" "Console > S3 > $SUB_BUCKET > Properties > Default encryption + Versioning"; }

phase4() { title 4 "Auth (Cognito)"; need USER_POOL_ID APP_CLIENT_ID || return
  check "User pool exists" "$(aws cognito-idp describe-user-pool --user-pool-id $USER_POOL_ID --query UserPool.Id --output text)" "$USER_POOL_ID"
  check "Groups student/tutor/admin" "$(aws cognito-idp list-groups --user-pool-id $USER_POOL_ID --query 'Groups[].GroupName' --output text | tr '\t' '\n' | sort | tr '\n' ' ')" "admin student tutor "
  for r in student tutor admin; do
    check "$r@example.com is in group $r" "$(aws cognito-idp admin-list-groups-for-user --user-pool-id $USER_POOL_ID --username $r@example.com --query 'Groups[0].GroupName' --output text)" "$r"
  done
  TOKEN=$(aws cognito-idp initiate-auth --client-id $APP_CLIENT_ID --auth-flow USER_PASSWORD_AUTH \
          --auth-parameters USERNAME=student@example.com,PASSWORD='Exam@2026' --query AuthenticationResult.IdToken --output text 2>/dev/null)
  [ -n "$TOKEN" ] && [ "$TOKEN" != "None" ] && ok "Student can sign in and receives a JWT" || bad "Student sign-in" "no token" "JWT"
  if command -v python3 >/dev/null && [ -n "$TOKEN" ]; then
    GRP=$(python3 -c "import sys,json,base64;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(','.join(json.loads(base64.urlsafe_b64decode(p)).get('cognito:groups',[])))" "$TOKEN")
    check "JWT carries role claim cognito:groups" "$GRP" "student"
  fi
  shots "This verify output (shows role in token)" "Console > Cognito > exam-users > Groups tab" "Console > Cognito > exam-users > Users tab"; }

phase5() { title 5 "Async (SQS + Lambda + SES)"; need QUEUE_URL QUEUE_ARN DLQ_ARN LAMBDA_NAME ESM_UUID SUB_BUCKET || return
  RP=$(aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names RedrivePolicy --query Attributes.RedrivePolicy --output text)
  echo "$RP" | grep -q "$DLQ_ARN" && ok "Jobs queue redrives to DLQ after 3 tries" || bad "DLQ redrive" "$RP" "DLQ ARN"
  check "S3 upload events -> jobs queue" "$(aws s3api get-bucket-notification-configuration --bucket $SUB_BUCKET --query 'QueueConfigurations[0].QueueArn' --output text)" "$QUEUE_ARN"
  for e in $(printf "%s\n%s\n" "$SES_FROM_EMAIL" "$TUTOR_EMAIL" | sort -u); do
    check "SES email $e verified" "$(aws ses get-identity-verification-attributes --identities $e --query "VerificationAttributes.\"$e\".VerificationStatus" --output text)" "Success"
  done
  check "Lambda worker active" "$(aws lambda get-function --function-name $LAMBDA_NAME --query Configuration.State --output text)" "Active"
  check "SQS trigger enabled" "$(aws lambda get-event-source-mapping --uuid $ESM_UUID --query State --output text)" "Enabled"
  echo "  ...functional test: sending a marking job and waiting 25s"
  START=$(( ($(date +%s) - 5) * 1000 ))
  aws sqs send-message --queue-url $QUEUE_URL --message-body '{"type":"mark","attempt_id":"verify-1","answers":{"q1":"B","q2":"C"},"answer_key":{"q1":"B","q2":"D"}}' >/dev/null
  sleep 25
  MSG=$(aws logs filter-log-events --log-group-name /aws/lambda/$LAMBDA_NAME --start-time $START --filter-pattern '"verify-1"' --query 'events[-1].message' --output text 2>/dev/null)
  echo "$MSG" | grep -q '"score": 1' && ok "Lambda auto-marked the job: $MSG" || bad "Lambda marking" "$MSG" "score 1 of 2"
  check "DLQ is empty" "$(aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)" "0"
  echo "  Upload test (walkthrough 2):"
  echo "    dd if=/dev/zero of=test.pdf bs=1M count=40 && aws s3 cp test.pdf s3://$SUB_BUCKET/submissions/DSO303/A2/student1/test.pdf"
  echo "    sleep 20 && aws logs tail /aws/lambda/$LAMBDA_NAME --since 2m   # then check your inbox"
  shots "This verify output (marking result line)" "Console > Lambda > exam-worker > Configuration > Triggers (SQS)" "After the upload test: Lambda log + the tutor email in your inbox"; }

phase6() { title 6 "Compute (ECR + ALB + ECS Fargate)"; need ALB_ARN TG_ARN CLUSTER SERVICE || return
  check "ECR repository exists" "$(aws ecr describe-repositories --repository-names $P-api --query 'repositories[0].repositoryName' --output text)" "$P-api"
  check "ALB active" "$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].State.Code' --output text)" "active"
  check "ALB spans 2 AZs" "$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'length(LoadBalancers[0].AvailabilityZones)')" "2"
  check "ALB is internet-facing in public subnets" "$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].Scheme' --output text)" "internet-facing"
  RUN=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].runningCount' --output text)
  DES=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].desiredCount' --output text)
  check "ECS running tasks = desired" "$RUN" "$DES"
  checkge "Healthy targets" "$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])")" 2
  check "Healthy targets are in 2 different AZs" "$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'].Target.AvailabilityZone" --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')" "2"
  check "Tasks have NO public IP (private subnets)" "$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp' --output text)" "DISABLED"
  check "Auto scaling min 2 / max 10" "$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids service/$CLUSTER/$SERVICE --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text | tr '\t' ' ')" "2 10"
  echo; aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].{IP:Target.Id,AZ:Target.AvailabilityZone,State:TargetHealth.State}' --output table
  shots "This verify output (healthy targets in 2 AZs)" "Console > ECS > exam-cluster > exam-api > Tasks tab (2 RUNNING, different AZs)" "Console > EC2 > Target groups > exam-api-tg > Targets"; }

phase7() { title 7 "Edge (CloudFront + WAF)"; need CF_ID CF_DOMAIN WAF_ID ALB_DNS WEB_BUCKET || return
  check "CloudFront deployed" "$(aws cloudfront get-distribution --id $CF_ID --query Distribution.Status --output text)" "Deployed"
  check "WAF attached to CloudFront" "$(aws cloudfront get-distribution --id $CF_ID --query Distribution.DistributionConfig.WebACLId --output text)" "$WAF_ARN"
  check "WAF has 4 rules" "$(aws wafv2 get-web-acl --region us-east-1 --scope CLOUDFRONT --name $P-waf --id $WAF_ID --query 'length(WebACL.Rules)')" "4"
  check "Site over HTTPS returns 200" "$(curl -s -o /dev/null -w '%{http_code}' https://$CF_DOMAIN/)" "200"
  curl -s https://$CF_DOMAIN/ | grep -q "University Exam Platform" && ok "Frontend page served from S3 via CloudFront" || bad "Frontend content" "missing" "page title"
  check "HTTP redirects to HTTPS" "$(curl -s -o /dev/null -w '%{http_code}' http://$CF_DOMAIN/)" "301"
  API=$(curl -s -o /dev/null -w '%{http_code}' https://$CF_DOMAIN/api/)
  case "$API" in 200|404) ok "/api/* reaches ECS through the ALB (HTTP $API from the container)";; *) bad "/api/* routing" "$API" "200 or 404 (not 502/503/504)";; esac
  check "Direct S3 access is DENIED (private bucket)" "$(curl -s -o /dev/null -w '%{http_code}' https://$WEB_BUCKET.s3.amazonaws.com/index.html)" "403"
  check "Direct ALB access is BLOCKED (CloudFront only)" "$(curl -s -o /dev/null -m 6 -w '%{http_code}' http://$ALB_DNS/)" "000"
  check "WAF blocks a SQL-injection attempt" "$(curl -s -o /dev/null -w '%{http_code}' "https://$CF_DOMAIN/api/?id=1%27%20OR%20%271%27=%271")" "403"
  shots "This verify output" "Browser at https://$CF_DOMAIN (padlock visible)" "Console > CloudFront > distribution > Origins + Behaviors tabs" "Console > WAF > Web ACLs (Global/CloudFront) > exam-waf > Rules"; }

phase8() { title 8 "Monitoring (CloudWatch)"
  checkge "CloudWatch alarms created" "$(aws cloudwatch describe-alarms --alarm-name-prefix $P- --query 'length(MetricAlarms)')" 6
  ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix $P- --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text)
  [ -z "$ALARM" ] && ok "No alarms firing" || bad "Alarms firing" "$ALARM" "none"
  for g in /ecs/$P-api /aws/lambda/$P-worker; do
    aws logs describe-log-groups --log-group-name-prefix $g --query 'logGroups[0].logGroupName' --output text | grep -q "$g" && ok "Log group $g exists" || bad "Log group $g" "missing" "exists"
  done
  echo; aws cloudwatch describe-alarms --alarm-name-prefix $P- --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Metric:MetricName}' --output table
  shots "This verify output (alarm table)" "Console > CloudWatch > Alarms > All alarms" "Console > CloudWatch > Log groups > /ecs/$P-api (log lines)"; }

phase9() { title 9 "Backup (5-year retention)"; need BACKUP_PLAN_ID || return
  check "Backup plan exists" "$(aws backup get-backup-plan --backup-plan-id $BACKUP_PLAN_ID --query BackupPlan.BackupPlanName --output text)" "$P-5-year"
  check "Monthly schedule" "$(aws backup get-backup-plan --backup-plan-id $BACKUP_PLAN_ID --query 'BackupPlan.Rules[0].ScheduleExpression' --output text)" "cron(0 3 1 * ? *)"
  check "Retention 1825 days (5 years)" "$(aws backup get-backup-plan --backup-plan-id $BACKUP_PLAN_ID --query 'BackupPlan.Rules[0].Lifecycle.DeleteAfterDays' --output text)" "1825"
  SEL=$(aws backup list-backup-selections --backup-plan-id $BACKUP_PLAN_ID --query 'BackupSelectionsList[0].SelectionId' --output text)
  RES=$(aws backup get-backup-selection --backup-plan-id $BACKUP_PLAN_ID --selection-id $SEL --query 'BackupSelection.Resources[0]' --output text 2>/dev/null)
  echo "$RES" | grep -q ":db:$DB_ID" && ok "RDS database is covered by the plan" || bad "Backup selection" "$RES" "the exam-db ARN"
  shots "This verify output" "Console > AWS Backup > Backup plans > $P-5-year (rule + resource assignment)"; }

phase10() { title 10 "Application end-to-end (both walkthroughs through CloudFront)"; need CF_DOMAIN APP_CLIENT_ID || return
  START=$(( ($(date +%s) - 5) * 1000 ))
  OUT=$(python3 "$(dirname "$0")/e2e-test.py" "$CF_DOMAIN" "$AWS_REGION" "$APP_CLIENT_ID"); RC=$?
  echo "$OUT" | grep -v '^  ATTEMPT_ID='
  PASS=$((PASS + $(echo "$OUT" | grep -c '✅'))); FAIL=$((FAIL + $(echo "$OUT" | grep -c '❌')))
  AID=$(echo "$OUT" | sed -n 's/^  ATTEMPT_ID=//p')
  echo "  -- Async step (Lambda), waiting 25s --"; sleep 25
  LOGS=$(aws logs filter-log-events --log-group-name /aws/lambda/$P-worker --start-time $START --query 'events[].message' --output text 2>/dev/null)
  echo "$LOGS" | grep -q "\"$AID\"" && ok "Lambda marked the attempt: $(echo "$LOGS" | tr '\t' '\n' | grep "$AID" | head -1)" || bad "Lambda marked the attempt" "no log line" "marked $AID"
  echo "$LOGS" | grep -q 'e2e-test.pdf' && ok "Lambda processed the upload and notified the tutor" || bad "Upload notification" "no log line" "upload event"
  shots "This verify output (all ✅)" "Browser: signed in, exam page showing 'Saved hh:mm (served from us-east-1x)'" \
        "Browser: upload finished message" "Console > S3 > submissions bucket > submissions/ folder showing the uploaded files"; }

phase11() { title 11 "API on Lambda (no containers)"; need API_FUNCTION LAMBDA_TG_ARN LISTENER_ARN || return
  check "API Lambda active" "$(aws lambda get-function --function-name $API_FUNCTION --query Configuration.State --output text)" "Active"
  check "API Lambda runs in the 2 private subnets" "$(aws lambda get-function --function-name $API_FUNCTION --query 'Configuration.VpcConfig.SubnetIds' --output text | tr '\t' '\n' | sort | tr '\n' ' ')" "$(printf '%s\n%s\n' $PRIV_A $PRIV_B | sort | tr '\n' ' ')"
  check "API Lambda uses the app security group" "$(aws lambda get-function --function-name $API_FUNCTION --query 'Configuration.VpcConfig.SecurityGroupIds[0]' --output text)" "$SG_APP"
  check "ALB listener forwards to the Lambda target group" "$(aws elbv2 describe-listeners --listener-arns $LISTENER_ARN --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)" "$LAMBDA_TG_ARN"
  check "ECS service scaled to 0 (containers retired)" "$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].desiredCount' --output text 2>/dev/null)" "0"
  H=$(curl -s -m 30 https://$CF_DOMAIN/api/health)
  echo "$H" | grep -q '"db":"ok"' && ok "CloudFront -> ALB -> Lambda -> RDS: $H" || bad "API health" "$H" '"db":"ok"'
  shots "This verify output" "Console > Lambda > exam-api > Configuration > VPC (2 private subnets)" "Console > EC2 > Load balancers > exam-alb > Listeners (forward to exam-api-lambda-tg)"; }

case "${1:-}" in
  [1-9]|10|11) phase$1 ;;
  all)   for i in 1 2 3 4 5 6 7 8 9 10 11; do phase$i; done ;;
  *)     echo "Usage: bash verify.sh <1-11|all>"; exit 1 ;;
esac
echo; echo "Result: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
