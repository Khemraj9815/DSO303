#!/usr/bin/env bash
# Phase 7 - Edge: WAF, CloudFront (S3 frontend + /api/* -> ALB), private S3 access via OAC
set -euo pipefail; DIR="$(cd "$(dirname "$0")" && pwd)"; source "$DIR/00-config.sh"
TMP=$(mktemp -d)

step "7.1 WAF web ACL (CloudFront scope lives in us-east-1)"
cat > "$TMP/rules.json" <<'JSON'
[
 {"Name":"AWS-CommonRuleSet","Priority":0,"OverrideAction":{"None":{}},
  "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}},
  "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"common"}},
 {"Name":"AWS-SQLiRuleSet","Priority":1,"OverrideAction":{"None":{}},
  "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesSQLiRuleSet"}},
  "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"sqli"}},
 {"Name":"AWS-KnownBadInputs","Priority":2,"OverrideAction":{"None":{}},
  "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesKnownBadInputsRuleSet"}},
  "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"badinputs"}},
 {"Name":"RateLimitPerIP","Priority":3,"Action":{"Block":{}},
  "Statement":{"RateBasedStatement":{"Limit":5000,"AggregateKeyType":"IP"}},
  "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"ratelimit"}}
]
JSON
read -r WAF_ARN WAF_ID < <(aws wafv2 create-web-acl --region us-east-1 --name "$P-waf" --scope CLOUDFRONT \
  --default-action Allow={} --rules "file://$TMP/rules.json" \
  --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName="$P-waf" \
  --query 'Summary.[ARN,Id]' --output text)
save WAF_ARN "$WAF_ARN"; save WAF_ID "$WAF_ID"

step "7.2 Origin Access Control (CloudFront signs requests to the private frontend bucket)"
save OAC_ID "$(aws cloudfront create-origin-access-control --origin-access-control-config \
  Name="$P-oac",SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
  --query OriginAccessControl.Id --output text)"

step "7.3 CloudFront distribution"
# AWS managed policy IDs: CachingOptimized, CachingDisabled, AllViewerExceptHostHeader
CACHE_OPT=658327ea-f89d-4fab-a63d-7e88639e58f6
CACHE_OFF=4135ea2d-6df8-44a3-9df3-4b5a84be39ad
ORIGIN_ALL=b689b0a8-53d0-40ab-baf2-68738e2966ac
cat > "$TMP/dist.json" <<JSON
{"CallerReference":"$P-$(date +%s)","Comment":"Exam platform","Enabled":true,"DefaultRootObject":"index.html",
 "PriceClass":"PriceClass_200","HttpVersion":"http2and3","WebACLId":"$WAF_ARN",
 "Origins":{"Quantity":2,"Items":[
   {"Id":"s3-frontend","DomainName":"$WEB_BUCKET.s3.$AWS_REGION.amazonaws.com",
    "S3OriginConfig":{"OriginAccessIdentity":""},"OriginAccessControlId":"$OAC_ID"},
   {"Id":"alb-api","DomainName":"$ALB_DNS",
    "CustomOriginConfig":{"HTTPPort":80,"HTTPSPort":443,"OriginProtocolPolicy":"http-only"}}]},
 "DefaultCacheBehavior":{"TargetOriginId":"s3-frontend","ViewerProtocolPolicy":"redirect-to-https",
   "CachePolicyId":"$CACHE_OPT","Compress":true,
   "AllowedMethods":{"Quantity":2,"Items":["GET","HEAD"],"CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}}},
 "CacheBehaviors":{"Quantity":1,"Items":[
   {"PathPattern":"/api/*","TargetOriginId":"alb-api","ViewerProtocolPolicy":"https-only",
    "CachePolicyId":"$CACHE_OFF","OriginRequestPolicyId":"$ORIGIN_ALL","Compress":true,
    "AllowedMethods":{"Quantity":7,"Items":["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                      "CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}}}]}}
JSON
read -r CF_ID CF_DOMAIN < <(aws cloudfront create-distribution --distribution-config "file://$TMP/dist.json" \
  --query 'Distribution.[Id,DomainName]' --output text)
save CF_ID "$CF_ID"; save CF_DOMAIN "$CF_DOMAIN"

step "7.4 Frontend bucket policy: only THIS distribution may read"
cat > "$TMP/bucket-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"AllowCloudFrontOAC","Effect":"Allow",
  "Principal":{"Service":"cloudfront.amazonaws.com"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::$WEB_BUCKET/*",
  "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CF_ID"}}}]}
JSON
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy "file://$TMP/bucket-policy.json"

step "7.5 Upload frontend + lock submissions CORS to the CloudFront domain"
aws s3 sync "$DIR/frontend" "s3://$WEB_BUCKET/" --delete
cat > "$TMP/cors.json" <<JSON
{"CORSRules":[{"AllowedOrigins":["https://$CF_DOMAIN"],"AllowedMethods":["POST","PUT","GET"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}
JSON
aws s3api put-bucket-cors --bucket "$SUB_BUCKET" --cors-configuration "file://$TMP/cors.json"

echo "  waiting for CloudFront to deploy (5-15 min)..."
aws cloudfront wait distribution-deployed --id "$CF_ID"
echo; echo "Phase 7 done. Open: https://$CF_DOMAIN"
echo "Optional Route 53: only if you own a domain - add an ALIAS record to $CF_DOMAIN (needs an ACM cert in us-east-1)."
