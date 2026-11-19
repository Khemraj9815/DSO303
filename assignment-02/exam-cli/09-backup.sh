#!/usr/bin/env bash
# Phase 9 - 5-year retention: AWS Backup monthly RDS backups kept 1825 days (RDS's own backups max out at 35)
set -euo pipefail; source "$(dirname "$0")/00-config.sh"
TMP=$(mktemp -d)

step "9.1 Backup vault + plan"
aws backup create-backup-vault --backup-vault-name "$P-vault" >/dev/null; save BACKUP_VAULT "$P-vault"
cat > "$TMP/plan.json" <<JSON
{"BackupPlanName":"$P-5-year","Rules":[{"RuleName":"monthly-5y","TargetBackupVaultName":"$P-vault",
  "ScheduleExpression":"cron(0 3 1 * ? *)","StartWindowMinutes":60,"CompletionWindowMinutes":180,
  "Lifecycle":{"DeleteAfterDays":1825}}]}
JSON
save BACKUP_PLAN_ID "$(aws backup create-backup-plan --backup-plan "file://$TMP/plan.json" --query BackupPlanId --output text)"

step "9.2 Backup role + select the RDS database"
if [ -n "${LAB_ROLE_ARN:-}" ]; then BACKUP_ROLE_ARN="$LAB_ROLE_ARN"
else
  cat > "$TMP/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"backup.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  BACKUP_ROLE_ARN=$(aws iam create-role --role-name "$P-backup-role" --assume-role-policy-document "file://$TMP/trust.json" --query Role.Arn --output text)
  aws iam attach-role-policy --role-name "$P-backup-role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup
  aws iam attach-role-policy --role-name "$P-backup-role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores
  sleep 15
fi
save BACKUP_ROLE_ARN "$BACKUP_ROLE_ARN"
save BACKUP_SELECTION_ID "$(aws backup create-backup-selection --backup-plan-id "$BACKUP_PLAN_ID" --backup-selection \
  "{\"SelectionName\":\"exam-db\",\"IamRoleArn\":\"$BACKUP_ROLE_ARN\",\"Resources\":[\"arn:aws:rds:$AWS_REGION:$ACCOUNT_ID:db:$DB_ID\"]}" \
  --query SelectionId --output text)"
echo; echo "Phase 9 done. All infrastructure is built."
