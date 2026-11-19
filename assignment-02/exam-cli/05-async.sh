#!/usr/bin/env bash
# Phase 5 - Async: SQS queue + DLQ, S3 upload events -> SQS, SES sender, Lambda worker
set -euo pipefail; DIR="$(cd "$(dirname "$0")" && pwd)"; source "$DIR/00-config.sh"
TMP=$(mktemp -d)

step "5.1 Dead-letter queue + main jobs queue (3 tries, then DLQ)"
save DLQ_URL "$(aws sqs create-queue --queue-name "$P-jobs-dlq" --attributes MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true --query QueueUrl --output text)"
save DLQ_ARN "$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
cat > "$TMP/q.json" <<JSON
{"VisibilityTimeout":"60","SqsManagedSseEnabled":"true",
 "RedrivePolicy":"{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"}
JSON
save QUEUE_URL "$(aws sqs create-queue --queue-name "$P-jobs" --attributes "file://$TMP/q.json" --query QueueUrl --output text)"
save QUEUE_ARN "$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

step "5.2 Allow S3 to send upload events to the queue, then turn on the notification"
cat > "$TMP/qpolicy.json" <<JSON
{"Policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"s3.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QUEUE_ARN\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"arn:aws:s3:::$SUB_BUCKET\"}}}]}"}
JSON
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "file://$TMP/qpolicy.json"
cat > "$TMP/notif.json" <<JSON
{"QueueConfigurations":[{"QueueArn":"$QUEUE_ARN","Events":["s3:ObjectCreated:*"],
  "Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"submissions/"}]}}}]}
JSON
aws s3api put-bucket-notification-configuration --bucket "$SUB_BUCKET" --notification-configuration "file://$TMP/notif.json"

step "5.3 SES: verify sender/tutor email (CLICK THE LINK in the email AWS sends you)"
for e in $(printf "%s\n%s\n" "$SES_FROM_EMAIL" "$TUTOR_EMAIL" | sort -u); do
  aws ses verify-email-identity --email-address "$e"; echo "  verification email sent to $e"
done

step "5.4 Lambda execution role"
if [ -n "${LAB_ROLE_ARN:-}" ]; then
  save LAMBDA_ROLE_ARN "$LAB_ROLE_ARN"; echo "  using Learner Lab LabRole"
else
  cat > "$TMP/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  save LAMBDA_ROLE_ARN "$(aws iam create-role --role-name "$P-worker-role" --assume-role-policy-document "file://$TMP/trust.json" --query Role.Arn --output text)"
  aws iam attach-role-policy --role-name "$P-worker-role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole
  aws iam put-role-policy --role-name "$P-worker-role" --policy-name ses-send \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ses:SendEmail"],"Resource":"*"}]}'
  echo "  waiting 15s for IAM to propagate..."; sleep 15
fi

step "5.5 Lambda worker + SQS trigger"
(cd "$DIR/lambda" && rm -f worker.zip && zip -q worker.zip worker.py)
aws lambda create-function --function-name "$P-worker" --runtime python3.12 --handler worker.handler \
  --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$DIR/lambda/worker.zip" --timeout 10 --memory-size 256 \
  --environment "Variables={FROM_EMAIL=$SES_FROM_EMAIL,TUTOR_EMAIL=$TUTOR_EMAIL}" >/dev/null
aws lambda wait function-active-v2 --function-name "$P-worker"
save LAMBDA_NAME "$P-worker"
aws logs put-retention-policy --log-group-name "/aws/lambda/$P-worker" --retention-in-days 30 2>/dev/null \
  || { aws logs create-log-group --log-group-name "/aws/lambda/$P-worker"; aws logs put-retention-policy --log-group-name "/aws/lambda/$P-worker" --retention-in-days 30; }
save ESM_UUID "$(aws lambda create-event-source-mapping --function-name "$P-worker" --event-source-arn "$QUEUE_ARN" \
  --batch-size 5 --function-response-types ReportBatchItemFailures --query UUID --output text)"
echo; echo "Phase 5 done. Remember to click the SES verification link(s)."
