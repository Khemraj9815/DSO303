#!/usr/bin/env bash
# Shared settings + helpers. Every other script sources this file.
# >>> EDIT THESE TWO LINES BEFORE RUNNING 05-async.sh <<<
export SES_FROM_EMAIL="your-email@example.com"     # sender (must be verified in SES)
export TUTOR_EMAIL="your-email@example.com"        # receives "new submission" emails (verify too)

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AZ_A="${AWS_REGION}a" AZ_B="${AWS_REGION}b"
export P="exam"                                      # name prefix for everything
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export IDS="$(dirname "${BASH_SOURCE[0]}")/ids.env"
touch "$IDS"; source "$IDS"

# save NAME VALUE  -> stores the ID in ids.env (re-runs overwrite) and exports it
save() { grep -v "^export $1=" "$IDS" > "$IDS.tmp" || true; mv "$IDS.tmp" "$IDS"
         echo "export $1=\"$2\"" >> "$IDS"; export "$1=$2"; echo "  $1=$2"; }
tagspec() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=exam-platform}]"; }
step() { echo; echo "=== $* ==="; }

# AWS Academy Learner Lab cannot create IAM roles but provides LabRole; use it when present.
if aws iam get-role --role-name LabRole >/dev/null 2>&1; then
  export LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
fi
