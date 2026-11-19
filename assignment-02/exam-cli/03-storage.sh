#!/usr/bin/env bash
# Phase 3 - Storage: submissions bucket (private, encrypted, versioned, 5-year lifecycle) + frontend bucket
set -euo pipefail; source "$(dirname "$0")/00-config.sh"
TMP=$(mktemp -d)

mkbucket() { # name
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$1" >/dev/null
  else aws s3api create-bucket --bucket "$1" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
}

step "3.1 Submissions bucket"
save SUB_BUCKET "$P-submissions-$ACCOUNT_ID"
mkbucket "$SUB_BUCKET"
aws s3api put-bucket-versioning --bucket "$SUB_BUCKET" --versioning-configuration Status=Enabled

step "3.2 Lifecycle: 30d -> Standard-IA, 365d -> Glacier, delete after 5 years (1825d)"
cat > "$TMP/lifecycle.json" <<JSON
{"Rules":[{"ID":"submissions-5-years","Status":"Enabled","Filter":{"Prefix":"submissions/"},
  "Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"},{"Days":365,"StorageClass":"GLACIER"}],
  "Expiration":{"Days":1825},
  "NoncurrentVersionExpiration":{"NoncurrentDays":30},
  "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}
JSON
aws s3api put-bucket-lifecycle-configuration --bucket "$SUB_BUCKET" --lifecycle-configuration "file://$TMP/lifecycle.json"

step "3.3 CORS (browser uploads with presigned POST; tightened to the CloudFront domain in 07-edge.sh)"
cat > "$TMP/cors.json" <<JSON
{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["POST","PUT","GET"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}
JSON
aws s3api put-bucket-cors --bucket "$SUB_BUCKET" --cors-configuration "file://$TMP/cors.json"

step "3.4 Frontend bucket (private; only CloudFront will read it)"
save WEB_BUCKET "$P-frontend-$ACCOUNT_ID"
mkbucket "$WEB_BUCKET"
echo; echo "Phase 3 done."
