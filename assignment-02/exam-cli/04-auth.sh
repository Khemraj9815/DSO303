#!/usr/bin/env bash
# Phase 4 - Auth: Cognito user pool with student / tutor / admin groups + one test user per role
set -euo pipefail; source "$(dirname "$0")/00-config.sh"

step "4.1 User pool + app client"
save USER_POOL_ID "$(aws cognito-idp create-user-pool --pool-name "$P-users" \
  --policies 'PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}' \
  --auto-verified-attributes email --username-attributes email \
  --query UserPool.Id --output text)"
save APP_CLIENT_ID "$(aws cognito-idp create-user-pool-client --user-pool-id "$USER_POOL_ID" --client-name "$P-web" \
  --no-generate-secret --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --query UserPoolClient.ClientId --output text)"

step "4.2 Role groups"
for g in student tutor admin; do
  aws cognito-idp create-group --user-pool-id "$USER_POOL_ID" --group-name "$g" --description "$g role" >/dev/null
  echo "  group: $g"
done

step "4.3 Test users (password: Exam@2026)"
for r in student tutor admin; do
  u="$r@example.com"
  aws cognito-idp admin-create-user --user-pool-id "$USER_POOL_ID" --username "$u" \
    --user-attributes Name=email,Value="$u" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$USER_POOL_ID" --username "$u" --password 'Exam@2026' --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id "$USER_POOL_ID" --username "$u" --group-name "$r"
  echo "  user: $u -> $r"
done

step "4.4 Test sign-in as the student (should print a token)"
aws cognito-idp initiate-auth --client-id "$APP_CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=student@example.com,PASSWORD='Exam@2026' \
  --query 'AuthenticationResult.IdToken' --output text | cut -c1-60; echo "  ...(token truncated)"
echo; echo "Phase 4 done."
