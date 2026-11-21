# Cost and Service Report – Online Exam Platform in ap-southeast-1 (Singapore)

## Introduction

In Assignment 2, an online exam and assignment-submission platform was designed and deployed on AWS for a university with 8,000 students and about 400 staff. Students sit timed exams with answers autosaved every 30 seconds and upload assignments of up to 50 MB; tutors mark and release results. The platform runs on CloudFront and WAF, an Application Load Balancer, Lambda functions in private subnets across two Availability Zones, RDS PostgreSQL Multi-AZ, S3, SQS and SES.

This assignment asks what that platform would **cost to run in the Asia Pacific (Singapore) Region (ap-southeast-1)**, whether it is **affordable** within a budget of **USD 1,000 per month averaged over the year**, and **where it would fail or slow down**. The year has two load profiles: **10 normal months** (300–500 concurrent users) and **2 exam months** (a peak of 3,000 students starting one exam within 5 minutes). The resilience targets from Assignment 2 still apply: **RPO 5 minutes, RTO 1 hour, survive the loss of one Availability Zone, and keep files for 5 years.**

### Aims and objectives

**Aim:** decide, with priced evidence, whether the exam platform is affordable and resilient enough to run in Singapore, and make it cheaper where possible without weakening its resilience.

**Objectives:**
1. Price every service of the design in the **AWS Pricing Calculator** for both load profiles, including the **hidden costs** (data transfer out, NAT gateway charges, CloudWatch Logs, KMS requests, backups).
2. Identify the **most expensive components** and explain why they cost what they do.
3. Compare key **service choices with alternatives** on cost, performance, resilience and effort.
4. Apply and quantify **cost optimizations**, recording the saving of each.
5. Give a **feasibility verdict** against the budget, the exam peak, the RPO and the RTO.

Prices were taken from the AWS Pricing Calculator (Region: Asia Pacific (Singapore)) on **21 November 2026**, in USD.

## 1. Load profiles and usage assumptions

| Assumption | Normal month (10/year) | Exam month (2/year) | Reasoning |
|---|---|---|---|
| Users | 8,000 students + 400 staff | Same | Brief |
| Concurrent users | ~400 average, 12 active hours/day | Same, **plus exams** | Brief: 300–500 concurrent |
| Exam sittings | 0 | 32,000 (8,000 students × 4 exams × 60 min) | Peak: 3,000 students start within 5 min |
| API requests (CloudFront → ALB → Lambda) | **8.64 million** | **13.12 million** | ~1 request/min per active user; each exam sitting adds 120 autosaves (every 30 s) + ~20 calls |
| Average requests per second (over 730 h) | 3.3 | 5 | Monthly requests ÷ 2,628,000 s |
| CloudFront data out / requests | ~145 GB / 10.08 M | ~210 GB / 14.72 M | Page assets + API responses |
| Data through CloudFront to origin | 4 GB | 7 GB | Autosave/submit request bodies (~0.5 KB each) |
| Assignment uploads | 10,000 files × 8 MB = 80 GB | Same | Direct to S3 by presigned URL (never through CloudFront or Lambda) |
| Lambda `exam-api` | 120 ms, 512 MB, 512 MB ephemeral storage | Same | One DB round trip per request; no temporary files |
| Lambda `exam-worker` | 22,000 jobs | 54,000 jobs | Uploads + emails; exams add 32,000 marking jobs |
| Emails | 12,000 | 44,000 | Tutor notifications + results |
| Database data | 10 GB used (50 GB gp3 provisioned) | Same | Text answers; +20%/year |
| S3 storage (year-1 average) | 80 GB Standard + 400 GB Standard-IA | Same | Lifecycle: IA after 30 days, archive after 365, delete after 5 years |

**Free tiers:** the always-free allowances are applied where the calculator asks for them to be excluded manually: CloudFront 1 TB and 10 M requests, Lambda 1 M requests and 400,000 GB-seconds, Cognito 10,000 MAU, and 100 GB/month of data transfer out. Twelve-month new-account offers are **not** used.

## 2. Monthly cost per service

### Assignment 2 design priced in Singapore (normal month)

The A2 design sized for the exam peak all year: db.t4g.medium Multi-AZ On-Demand, 2 NAT gateways, x86 Lambda, Standard CloudWatch Logs.

| Service | Normal month | Source |
|---|---:|---|
| Amazon RDS for PostgreSQL (db.t4g.medium, Multi-AZ, On-Demand, 50 GB gp3) | $206.52 | Calculator |
| NAT gateways (2, one per AZ) | $86.20 | Calculator |
| Application Load Balancer | $19.13 | Calculator |
| AWS WAF (1 web ACL, 1 rule + 3 managed rule groups, 10.08 M requests) | $15.05 | Calculator: $5 web ACL + 4 × $1 rules + $6.05 requests |
| Public IPv4 addresses (4: 2 NAT + 2 ALB) | $14.60 | 4 × $0.005/h × 730 h |
| Amazon CloudWatch (8.6 GB Standard logs, 6 alarms) | $6.02 | 8.6 GB × $0.70/GB |
| S3 Standard-IA (400 GB) | $5.72 | Calculator |
| AWS Lambda exam-api (x86) | $3.50 | Calculator |
| S3 Standard (80 GB) | $2.05 | Calculator |
| Amazon SES (12,000 emails) | $1.20 | 12,000 × $0.10/1,000 (emails sent from Lambda) |
| AWS Backup – RDS (monthly snapshots) | $0.74 | Calculator |
| Amazon CloudFront (India edge) | $0.74 | Calculator |
| Amazon Route 53 (1 hosted zone) | $0.50 | Calculator |
| AWS Secrets Manager (1 secret) | $0.43 | Calculator |
| Amazon SQS (0.7 M requests) | $0.28 | Calculator |
| AWS KMS (AWS-managed keys, 8,000 requests) | $0.02 | Calculator |
| AWS Lambda exam-worker | $0.00 | Calculator |
| Amazon Cognito (8,400 MAU, Essentials) | $0.00 | Calculator |
| **Total, baseline normal month** | **≈ $362.70** | |

## 3. Hidden costs

| Hidden cost | What the calculator showed | Explanation |
|---|---|---|
| **Data transfer out** | **$0.00** (CloudFront data out 0 GB after the free 1 TB; S3 downloads inside the free 100 GB) | CloudFront charges $0.109/GB at India edges, but the platform's ~145–210 GB/month is inside the always-free 1 TB. Origin → CloudFront transfer is free. Only data sent **to** the origin is billed ($0.16/GB × 4 GB = $0.64). |
| **NAT gateway** | **$86.20/month** for two gateways (2 × 730 h), plus ~$0.059 per GB processed | Almost all of it is the **hourly** charge: the gateways cost this even with zero traffic. The data-processing part is cents. That makes NAT the clearest hidden cost in the A2 design. |
| **Public IPv4 addresses** | $14.60/month (4 addresses) | AWS charges $0.005/h for every public IPv4, including NAT Elastic IPs and the ALB's address in each AZ. |
| **CloudWatch Logs** | $6.02/month Standard → $3.01 Infrequent Access | ~1 KB of log per API request → 8.6–13.1 GB/month. The Infrequent Access log class halves the ingestion price ($0.70 → $0.35/GB). |
| **KMS requests** | $0.02/month | AWS-managed keys have no monthly key fee. 8,000 decrypts per month from Secrets Manager on Lambda cold starts. SSE-KMS on S3 **without** bucket keys would add a request per upload and download. |
| **Backups** | $0.74/month | RDS automated 7-day backups are free up to 100% of provisioned storage. AWS Backup's monthly snapshots are kept for 5 years and **grow every year**; the calculator shows the cost once all 60 are stored. |
| **SQS polling** | $0.28/month | The Lambda SQS trigger long-polls continuously (~0.65 M requests/month) even with no jobs. |
| **Multi-AZ** | RDS storage 50 GB costs **$13.80** (×2 for the standby) | Multi-AZ bills the hidden standby instance and its storage, which doubles the database cost. |
| **Cognito federation (risk)** | $0 for 8,400 direct users | If students sign in through university SSO (SAML/OIDC), only 50 MAU are free, which would add ~$125/month at $0.015/MAU. |

## 4. The three most expensive components

*(Normal month, Assignment 2 design.)*

1. **Amazon RDS for PostgreSQL Multi-AZ: $206.52 (57% of the baseline).** It is the only component sized for the 3,000-student peak instead of average load, and Multi-AZ doubles it by billing a standby instance and its storage in the second AZ. It is the price of RPO 0 and surviving an AZ loss.
2. **NAT gateways: $86.20 (24%).** A fixed hourly charge for two gateways (one per AZ, so neither AZ depends on the other), even though the Lambda sends almost no traffic through them.
3. **Application Load Balancer: $19.13 (5%).** Almost entirely the fixed hourly charge; the traffic uses only a fraction of one LCU.

**Pattern:** the expensive items are **always-on, per-hour resources**. Usage-priced services (Lambda, S3, SQS, CloudFront, SES) cost a few dollars at this scale, so the savings come from cutting fixed hours, not requests.

## 5. Service choices compared with alternatives

### 5.1 Backend: Lambda vs ECS Fargate vs EC2 Auto Scaling

| | **Lambda (chosen)** | ECS Fargate (A2's first build) | EC2 Auto Scaling |
|---|---|---|---|
| Cost | **$3.50/month** for 8.64 M requests (x86, before Arm) | Two always-on tasks + extra tasks for the peak + an image registry | 2 instances minimum in 2 AZs + patching time |
| Performance | Scales per request in seconds; cold starts ~1–2 s; **capped by the account concurrency quota (default 10)** | Steady latency; new tasks take 1–3 min | Slowest to scale; needs pre-warming |
| Resilience | Runs across both private subnets automatically | Tasks spread across AZs | ASG across AZs |
| Effort | A zip file, no images or OS | Docker image pipeline, task definitions | AMIs, OS patching, agents |

### 5.2 Database for answers: RDS Multi-AZ vs Aurora Serverless v2 vs DynamoDB

| | **RDS PostgreSQL Multi-AZ (chosen)** | Aurora Serverless v2 | DynamoDB on-demand |
|---|---|---|---|
| Cost | $206.52/month (db.t4g.medium, Multi-AZ, On-Demand, 50 GB) | Billed per ACU-hour with a minimum per instance, ×2 for a Multi-AZ reader, plus I/O | Per request; no idle cost |
| Performance | Fixed size: must be resized before exams | Scales automatically within seconds | Single-digit ms at any scale; no connection limit |
| Resilience | Synchronous standby, failover ~1–2 min | Failover usually < 30 s; storage 6 copies across 3 AZs | Multi-AZ by default, no failover event |
| Effort | Plain PostgreSQL; no code change | Same SQL, new cluster | Rewrite the data model (no joins or reports) |

### 5.3 Private traffic: NAT gateway vs VPC endpoints

| | NAT gateway ×2 (A2) | **Interface endpoints for SQS + Secrets Manager (chosen)** |
|---|---|---|
| Cost | **$86.20 + $14.60 (4 public IPv4) = $100.80/month** | **$37.97 + $7.30 (2 public IPv4) = $45.27/month** |
| Performance | Extra hop out to the internet and back | Private path inside AWS |
| Resilience | Needs one per AZ | Endpoint interfaces in both AZs |
| Effort | Works for any destination | The Lambda must not need the internet: Cognito signing keys bundled at deploy time, debug RDS call removed |

### 5.4 5-year file retention: S3 Standard vs Intelligent-Tiering vs Glacier

| | S3 Standard only | Intelligent-Tiering | **Lifecycle: Standard → Standard-IA (30 d) → Glacier (365 d) → delete (5 y) (chosen)** |
|---|---|---|---|
| Cost (year 1, per month) | 480 GB × Standard price | Automatic tiering + a monitoring fee per object | **$7.77** (80 GB Standard $2.05 + 400 GB IA $5.72) |
| Retrieval | Instant | Instant | IA instant (with a per-GB fee); Glacier minutes to hours |
| Effort | None | None | One lifecycle rule |

The access pattern is predictable (read in the first weeks, then almost never), so a lifecycle rule beats Intelligent-Tiering's monitoring fee.

## 6. Feasibility verdict

| Target | Result |
|---|---|
| **Budget**: $1,000/month averaged | Even the **unoptimized** Assignment 2 design costs about **$363 in a normal month**, roughly a third of the monthly budget. |
| **Peak**: 3,000 starts in 5 min | Feasible **with two conditions**: raise the Lambda concurrency quota from the account default of 10 to at least 100, and run db.t4g.medium during exam weeks. |
| **RPO 5 min** | Synchronous Multi-AZ standby (no committed data lost on AZ failure); PITR logs every 5 min; unsaved answers kept in the browser |
| **RTO 1 h** | AZ failover in minutes; point-in-time restore of a 10 GB database well under 1 h |
| **Survive loss of one AZ** | ALB, Lambda, endpoints and RDS span both AZs |
| **Files kept 5 years** | S3 lifecycle (delete at 1,825 days) + AWS Backup 60 monthly snapshots |

## 7. Optimizations and savings

| # | Optimization | Normal month before → after | Saving per month | Saving per year |
|---|---|---|---:|---:|
| 1 | NAT gateways → VPC interface endpoints (+ fewer public IPv4) | $100.80 → $45.27 | **$55.53** | $666 (×12) |
| 2 | CloudWatch Logs Standard → Infrequent Access log class | $6.02 → $3.01 | **$3.01** | $36 (×12) |

## 8. Prices used (from the AWS Pricing Calculator "Show calculations", ap-southeast-1, 21 Nov 2026)

| Item | Price |
|---|---|
| CloudFront data transfer out, India edge | $0.109/GB (first 1 TB/month free) |
| CloudFront data transfer to origin, India | $0.16/GB |
| CloudFront HTTPS requests, India | $0.0000012 per request (first 10 M/month free) |
| WAF | $5/web ACL, $1/rule or rule group, $0.60/million requests |
| NAT gateway | $86.20/month for 2 gateways (≈ $0.059/h each) |
| Public IPv4 address | $0.005/h |
| CloudWatch Logs ingestion | $0.70/GB Standard, $0.35/GB Infrequent Access |
| RDS PostgreSQL db.t4g.medium Multi-AZ + 50 GB gp3 | $206.52/month (storage $13.80 of it) |
| AWS PrivateLink, 2 interface endpoints × 2 AZs | $37.97/month |
| S3 Standard 80 GB / Standard-IA 400 GB (with requests) | $2.05 / $5.72 |