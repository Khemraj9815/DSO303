#!/usr/bin/env bash
# Phase 2 - Data: RDS PostgreSQL Multi-AZ in the private subnets; password generated + stored in Secrets Manager
set -euo pipefail; source "$(dirname "$0")/00-config.sh"

step "2.1 DB subnet group (private-a + private-b)"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$P-db-subnets" >/dev/null 2>&1; then
  echo "  (already exists - reusing)"
else
  aws rds create-db-subnet-group --db-subnet-group-name "$P-db-subnets" \
    --db-subnet-group-description "Private subnets for exam DB" --subnet-ids "$PRIV_A" "$PRIV_B" >/dev/null
fi
save DB_SUBNET_GROUP "$P-db-subnets"

# Free-plan accounts allow max 1 day of backup retention; use BACKUP_DAYS=7 on a paid plan.
BACKUP_DAYS="${BACKUP_DAYS:-1}"
step "2.2 RDS PostgreSQL Multi-AZ (encrypted, private, PITR ${BACKUP_DAYS} day(s), secret in Secrets Manager)"
aws rds create-db-instance --db-instance-identifier "$P-db" \
  --engine postgres --db-instance-class db.t3.micro \
  --allocated-storage 20 --storage-type gp3 \
  --db-name examdb --master-username examadmin --manage-master-user-password \
  --multi-az --storage-encrypted --no-publicly-accessible \
  --backup-retention-period "$BACKUP_DAYS" --copy-tags-to-snapshot \
  --db-subnet-group-name "$P-db-subnets" --vpc-security-group-ids "$SG_DB" \
  --tags Key=Project,Value=exam-platform >/dev/null
save DB_ID "$P-db"
echo "  waiting for RDS to become available (10-20 min for Multi-AZ)..."
aws rds wait db-instance-available --db-instance-identifier "$P-db"

save DB_ENDPOINT  "$(aws rds describe-db-instances --db-instance-identifier "$P-db" --query 'DBInstances[0].Endpoint.Address' --output text)"
save DB_SECRET_ARN "$(aws rds describe-db-instances --db-instance-identifier "$P-db" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
aws rds describe-db-instances --db-instance-identifier "$P-db" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,PrimaryAZ:AvailabilityZone,StandbyAZ:SecondaryAvailabilityZone,Encrypted:StorageEncrypted,Public:PubliclyAccessible}' --output table
echo; echo "Phase 2 done."