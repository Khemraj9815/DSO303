#!/usr/bin/env bash
# Phase 1 - Network: VPC, 2 public + 2 private subnets in 2 AZs, IGW, 1 NAT per AZ, routes, security groups
set -euo pipefail; source "$(dirname "$0")/00-config.sh"

step "1.1 VPC 10.0.0.0/16"
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tagspec vpc $P-vpc)" \
  --query Vpc.VpcId --output text); save VPC_ID "$VPC_ID"
aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

step "1.2 Subnets: public (ALB, NAT) and private (ECS, RDS) in each AZ"
mk() { aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$3" \
       --tag-specifications "$(tagspec subnet $P-$1)" --query Subnet.SubnetId --output text; }
save PUB_A  "$(mk public-a  10.0.1.0/24  $AZ_A)"
save PUB_B  "$(mk public-b  10.0.2.0/24  $AZ_B)"
save PRIV_A "$(mk private-a 10.0.11.0/24 $AZ_A)"
save PRIV_B "$(mk private-b 10.0.12.0/24 $AZ_B)"

step "1.3 Internet Gateway + public route table (0.0.0.0/0 -> IGW)"
save IGW_ID "$(aws ec2 create-internet-gateway --tag-specifications "$(tagspec internet-gateway $P-igw)" \
  --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
save RT_PUB "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tagspec route-table $P-rt-public)" \
  --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB_B" >/dev/null

step "1.4 One NAT Gateway per AZ (outbound only for private subnets; no cross-AZ dependency)"
save EIP_A "$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tagspec elastic-ip $P-eip-a)" --query AllocationId --output text)"
save EIP_B "$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tagspec elastic-ip $P-eip-b)" --query AllocationId --output text)"
save NAT_A "$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_A" \
  --tag-specifications "$(tagspec natgateway $P-nat-a)" --query NatGateway.NatGatewayId --output text)"
save NAT_B "$(aws ec2 create-nat-gateway --subnet-id "$PUB_B" --allocation-id "$EIP_B" \
  --tag-specifications "$(tagspec natgateway $P-nat-b)" --query NatGateway.NatGatewayId --output text)"
echo "  waiting for NAT gateways (1-3 min)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A" "$NAT_B"

step "1.5 Private route tables (private-a -> NAT A, private-b -> NAT B)"
for az in A B; do
  rt=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tagspec route-table $P-rt-private-${az,,})" \
       --query RouteTable.RouteTableId --output text); save RT_PRIV_$az "$rt"
  nat_var="NAT_$az"; sub_var="PRIV_$az"
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${!nat_var}" >/dev/null
  aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "${!sub_var}" >/dev/null
done

step "1.6 Security group chain: CloudFront -> ALB(80) -> App(80) -> DB(5432)"
CF_PL=$(aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text); save CF_PL "$CF_PL"
sg() { aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$P-$1" --description "$2" \
       --tag-specifications "$(tagspec security-group $P-$1)" --query GroupId --output text; }
save SG_ALB "$(sg alb-sg 'ALB - HTTP from CloudFront only')"
save SG_APP "$(sg app-sg 'App - port 80 from ALB only')"
save SG_DB  "$(sg db-sg  'DB - PostgreSQL from app only')"
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$CF_PL,Description=CloudFront}]" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 80   --source-group "$SG_ALB" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_DB"  --protocol tcp --port 5432 --source-group "$SG_APP" >/dev/null
echo; echo "Phase 1 done."
