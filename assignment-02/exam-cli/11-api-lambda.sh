#!/usr/bin/env bash
# Phase 11 - Run the API as a Lambda function behind the existing ALB (no Docker, no container image).
# Same app.py as the container; packaged as a zip. Re-run any time you change app/api or frontend/.
set -euo pipefail; DIR="$(cd "$(dirname "$0")" && pwd)"; source "$DIR/00-config.sh"
TMP=$(mktemp -d); FN="$P-api"; ROLE="$P-api-lambda-role"; TG_NAME="$P-api-lambda-tg"

step "11.1 Package the code (Linux wheels for Lambda, no Docker needed)"
BUILD="$TMP/build"; mkdir -p "$BUILD"
PIPARGS=(install -q --target "$BUILD" --platform manylinux2014_x86_64 --implementation cp --python-version 3.12
         --only-binary=:all: --upgrade "flask==3.1.*" "psycopg2-binary==2.9.*" "pyjwt[crypto]==2.*")
python3 -m pip "${PIPARGS[@]}" 2>/dev/null || python3 -m pip "${PIPARGS[@]}" --break-system-packages
cp "$DIR/app/api/app.py" "$DIR/app/api/lambda_handler.py" "$BUILD/"
(cd "$BUILD" && zip -qr "$TMP/api.zip" .)
echo "  package size: $(du -h "$TMP/api.zip" | cut -f1)"

step "11.2 Execution role (VPC access + logs, read DB secret, send to SQS, sign S3 uploads, read RDS AZ)"
if [ -n "${LAB_ROLE_ARN:-}" ]; then save API_LAMBDA_ROLE_ARN "$LAB_ROLE_ARN"
elif aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  save API_LAMBDA_ROLE_ARN "$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
else
  cat > "$TMP/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  save API_LAMBDA_ROLE_ARN "$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$TMP/trust.json" --query Role.Arn --output text)"
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
  NEW_ROLE=1
fi
if [ -z "${LAB_ROLE_ARN:-}" ]; then
  cat > "$TMP/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"$DB_SECRET_ARN"},
 {"Effect":"Allow","Action":"sqs:SendMessage","Resource":"$QUEUE_ARN"},
 {"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::$SUB_BUCKET/submissions/*"},
 {"Effect":"Allow","Action":"rds:DescribeDBInstances","Resource":"arn:aws:rds:$AWS_REGION:$ACCOUNT_ID:db:$DB_ID"}]}
JSON
  aws iam put-role-policy --role-name "$ROLE" --policy-name app-access --policy-document "file://$TMP/policy.json"
  [ -n "${NEW_ROLE:-}" ] && { echo "  waiting 15s for IAM to propagate..."; sleep 15; }
fi

step "11.3 Lambda function in BOTH private subnets (same app security group as the containers)"
ENVV="Variables={USER_POOL_ID=$USER_POOL_ID,APP_CLIENT_ID=$APP_CLIENT_ID,SUBMISSIONS_BUCKET=$SUB_BUCKET,QUEUE_URL=$QUEUE_URL,DB_HOST=$DB_ENDPOINT,DB_NAME=examdb,DB_SECRET_ARN=$DB_SECRET_ARN,DB_INSTANCE_ID=$DB_ID}"
if aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$TMP/api.zip" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FN"
  aws lambda update-function-configuration --function-name "$FN" --environment "$ENVV" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FN"; echo "  updated existing function"
else
  aws lambda create-function --function-name "$FN" --runtime python3.12 --handler lambda_handler.handler \
    --role "$API_LAMBDA_ROLE_ARN" --zip-file "fileb://$TMP/api.zip" --timeout 15 --memory-size 512 \
    --vpc-config "SubnetIds=$PRIV_A,$PRIV_B,SecurityGroupIds=$SG_APP" --environment "$ENVV" >/dev/null
  echo "  waiting for the function to attach to the VPC (1-3 min)..."
  aws lambda wait function-active-v2 --function-name "$FN"
fi
save API_FUNCTION "$FN"
save API_FUNCTION_ARN "$(aws lambda get-function --function-name "$FN" --query Configuration.FunctionArn --output text)"
aws logs create-log-group --log-group-name "/aws/lambda/$FN" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/aws/lambda/$FN" --retention-in-days 30

step "11.4 Lambda target group + point the ALB listener at it"
if ! LAMBDA_TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null); then
  LAMBDA_TG_ARN=$(aws elbv2 create-target-group --name "$TG_NAME" --target-type lambda --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws lambda add-permission --function-name "$FN" --statement-id alb-invoke --action lambda:InvokeFunction \
    --principal elasticloadbalancing.amazonaws.com --source-arn "$LAMBDA_TG_ARN" >/dev/null
  aws elbv2 register-targets --target-group-arn "$LAMBDA_TG_ARN" --targets Id="$API_FUNCTION_ARN"
fi
save LAMBDA_TG_ARN "$LAMBDA_TG_ARN"
aws elbv2 modify-listener --listener-arn "$LISTENER_ARN" --default-actions Type=forward,TargetGroupArn="$LAMBDA_TG_ARN" >/dev/null
echo "  ALB now forwards to the Lambda API"

step "11.5 Scale the ECS service to 0 (stop paying for containers; kept for rollback)"
aws application-autoscaling deregister-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/$CLUSTER/$SERVICE" 2>/dev/null || true
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null 2>&1 || true

step "11.6 Publish the exam web page + clear the CloudFront cache"
aws s3 sync "$DIR/frontend" "s3://$WEB_BUCKET/" --delete --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*" --query Invalidation.Id --output text >/dev/null

step "11.7 Smoke test (first call is a cold start: a few seconds)"
for i in 1 2 3; do
  OUT=$(curl -s -m 30 "https://$CF_DOMAIN/api/health") && echo "$OUT" | grep -q '"db":"ok"' && { echo "  $OUT"; break; }
  echo "  not ready yet (${OUT:-no response}), retrying in 10s..."; sleep 10
done
echo "  Lambda concurrency limit for this account: $(aws lambda get-account-settings --query AccountLimit.ConcurrentExecutions --output text)"
echo; echo "Phase 11 done. Open https://$CF_DOMAIN  (student@example.com / Exam@2026) - then run: bash verify.sh 11 && bash verify.sh 10"
echo "Logs: aws logs tail /aws/lambda/$FN --since 10m"
