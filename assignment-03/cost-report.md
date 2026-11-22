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


## 1. Load profiles and usage assumptions

| Assumption | Normal month (10/year) | Exam month (2/year) | Reasoning |
|---|---|---|---|
| Users | 8,000 students + 400 staff | Same | - |
| Concurrent users | ~400 average, 12 active hours/day | Same, **plus exams** | Brief: 300–500 concurrent |
| Exam sittings | 0 | 32,000 (8,000 students × 4 exams × 60 min) | Peak: 3,000 students start within 5 min |
| API requests (CloudFront → ALB → Lambda) | **8.64 million** | **13.12 million** | ~1 request/min per active user; each exam sitting adds 120 autosaves (every 30 s) + ~20 calls |
| Average requests per second (over 730 h) | 3.3 | 5 | Monthly requests ÷ 2,628,000 s |
| CloudFront data out / requests | ~145 GB / 10.08 M | ~210 GB / 14.72 M | Page assets + API responses |
| Data through CloudFront to origin | 4 GB | 7 GB | Autosave/submit request bodies (~0.5 KB each) |
| Assignment uploads | 10,000 files × 8 MB = 80 GB | Same | Direct to S3 by presigned URL (never through CloudFront or Lambda) |
| Lambda `exam-api` | 120 ms, 512 MB, 512 MB ephemeral storage | Same (exam export uses 13.2 M requests, +0.08 M ≈ $0.08) | One DB round trip per request; no temporary files |
| Lambda `exam-worker` | 22,000 jobs | 54,000 jobs | Uploads + emails; exams add 32,000 marking jobs |
| Emails | 12,000 | 44,000 | Tutor notifications + results |
| Database data | 10 GB used (100 GB gp3 provisioned) | Same | Text answers, with room to grow |
| S3 storage (year-1 average) | 80 GB Standard + 400 GB Standard-IA | Same | Lifecycle: IA after 30 days, archive after 365, delete after 5 years |

In most cases, there are certain limit of using free tier, for example, CloudFront free tier is 1 TB, so these kind of services are reducing the cost of the platform since our requirements are below the free tier limit. 
## 2. Monthly cost per service

The two estimates were built in the AWS Pricing Calculator (Region: Asia Pacific (Singapore)) and exported to `evidence/`. Both use the Assignment 2 architecture, but **two services are already entered with their optimized option**: the database as a **1-year Reserved Instance (Partial Upfront)** and CloudWatch with **Infrequent Access logs**. The tables below are copied exactly from the CSV exports.

### 2.1 Normal month (calculator export `calculator-normal-month.csv`)

| Service | Upfront | Monthly |
|---|---:|---:|
| Amazon RDS for PostgreSQL (db.t4g.medium, Multi-AZ, 100 GB gp3, **1-yr Reserved, Partial Upfront**) | $668.00 | $127.76 |
| NAT gateways (2, one per AZ) | — | $86.20 |
| Application Load Balancer | — | $19.42 |
| AWS WAF (1 web ACL, 1 rule + 3 managed groups, 10.08 M requests) | — | $15.05 |
| Public IPv4 addresses (4: 2 NAT + 2 ALB) | — | $14.60 |
| S3 Standard-Infrequent Access (400 GB) | — | $5.72 |
| AWS Lambda exam-api (8.64 M requests, x86) | — | $3.50 |
| Amazon CloudWatch (8.6 GB **Infrequent Access** logs) | — | $3.01 |
| S3 Standard (80 GB) | — | $2.05 |
| Amazon SES (12,000 emails) | — | $1.20 |
| Amazon CloudFront (India edge; 4 GB to origin, 80,000 billable requests) | — | $0.74 |
| AWS Backup – RDS (monthly snapshots) | — | $0.74 |
| Amazon Route 53 (1 hosted zone) | — | $0.50 |
| AWS Secrets Manager (1 secret) | — | $0.43 |
| Amazon SQS (0.7 M requests) | — | $0.28 |
| AWS KMS (AWS-managed keys) | — | $0.02 |
| AWS Lambda exam-worker (22,000 jobs) | — | $0.00 |
| Amazon Cognito (8,400 MAU) | — | $0.00 |
| Data transfer out | — | $0.00 |
| **Total (calculator)** | **$668.00** | **$281.22** |

Calculator "First 12 months total" for this estimate: **$4,042.64** (12 × $281.22 + $668 upfront).

### 2.2 Exam month (calculator export `calculator-exam-month.csv`)

| Service | Upfront | Monthly |
|---|---:|---:|
| Amazon RDS for PostgreSQL (db.t4g.medium, Multi-AZ, 100 GB gp3, **1-yr Reserved, Partial Upfront**) | $668.00 | $127.76 |
| NAT gateways (2, one per AZ) | — | $86.20 |
| Application Load Balancer | — | $19.54 |
| AWS WAF (14.72 M requests) | — | $17.83 |
| Public IPv4 addresses (4: 2 NAT + 2 ALB) | — | $14.60 |
| S3 Standard-Infrequent Access (400 GB) | — | $5.72 |
| AWS Lambda exam-api (13.2 M requests, x86) | — | $8.97 |
| Amazon CloudWatch (13.1 GB Infrequent Access logs) | — | $4.59 |
| S3 Standard (80 GB) | — | $2.05 |
| Amazon SES (44,000 emails) | — | $4.40 |
| Amazon CloudFront (7 GB to origin, 4.7 M billable requests) | — | $6.76 |
| AWS Backup – RDS (monthly snapshots) | — | $0.74 |
| Amazon Route 53 (1 hosted zone) | — | $0.50 |
| AWS Secrets Manager (1 secret) | — | $0.43 |
| Amazon SQS (0.8 M requests) | — | $0.32 |
| AWS KMS (AWS-managed keys) | — | $0.02 |
| AWS Lambda exam-worker (54,000 jobs) | — | $0.00 |
| Amazon Cognito (8,400 MAU) | — | $0.00 |
| Data transfer out | — | $0.00 |
| **Total (calculator)** | **$668.00** | **$300.43** |

Calculator "First 12 months total" for this estimate: **$4,273.16**.

The exam month costs only **$19.21 more** than a normal month (+6.8%). The expensive services (database, NAT, load balancer, IPv4) are fixed hourly charges paid every month anyway. Exam traffic only moves the usage-priced services: CloudFront requests (+$6.02), Lambda (+$5.47), SES (+$3.20), WAF (+$2.78), logs (+$1.58).

### 2.3 Annual total and cost per student

The Reserved Instance's **$668 upfront is paid once per year** (one database), not once per estimate.

| | Assignment 2 design (all On-Demand, Standard logs) | **As estimated in the calculator** (Reserved DB + IA logs) | Final design (+ VPC endpoints instead of NAT) |
|---|---:|---:|---:|
| Normal month | $376.79 | $281.22 + $55.67 upfront share = $336.89 | $281.36 |
| Exam month | $397.58 | $300.43 + $55.67 upfront share = $356.10 | $300.97 (section 2.4) |
| **Annual total (10 normal + 2 exam)** | **$4,563.10** | **$4,081.06** (= 10 × $281.22 + 2 × $300.43 + $668) | **$3,415.50** |
| Average per month | $380.26 | $340.09 | **$284.63** |
| Share of the $1,000/month budget | 38.0% | 34.0% | **28.5%** |
| **Cost per student per year** (8,000) | $0.57 | $0.51 | **$0.43** |

How the other two columns are derived from the calculator:
- **Assignment 2 design:** the CSV totals with the Reserved database row ($127.76 + upfront) replaced by **On-Demand db.t4g.medium Multi-AZ 100 GB = $220.32** (same configuration in the first calculator export), and Infrequent Access logs replaced by **Standard logs** at the calculator's $0.70/GB (normal 8.6 GB = $6.02; exam 13.1 GB = $9.17).
- **Final design:** exam month from the optimized calculator export (section 2.4, $207.33 + PrivateLink $37.97 = $245.30). Normal month: the normal-month CSV with NAT ($86.20) + 4 public IPv4 ($14.60) replaced by PrivateLink $37.97 + 2 public IPv4 $7.30 = $225.69. Plus the $668 upfront once a year.

### 2.4 Final exam month (calculator export `calculator-exam-month-optimized.csv`)

The final design: no NAT gateways, 2 public IPv4 addresses, Reserved database, Infrequent Access logs. Copied from the CSV:

| Service | Upfront | Monthly |
|---|---:|---:|
| Amazon RDS for PostgreSQL (db.t4g.medium, Multi-AZ, 100 GB, 1-yr Reserved, Partial Upfront) | $668.00 | $127.76 |
| Application Load Balancer | — | $19.54 |
| AWS WAF (14.72 M requests) | — | $17.83 |
| AWS Lambda exam-api (13.2 M requests) | — | $8.97 |
| Public IPv4 addresses (**2**: ALB only) | — | $7.30 |
| Amazon CloudFront (7 GB to origin, 4.7 M billable requests) | — | $6.76 |
| S3 Standard-Infrequent Access (400 GB) | — | $5.72 |
| Amazon CloudWatch (13.1 GB Infrequent Access logs) | — | $4.59 |
| Amazon SES (44,000 emails) | — | $4.40 |
| S3 Standard (80 GB) | — | $2.05 |
| AWS Secrets Manager (2 secrets as entered) | — | $0.83 |
| AWS Backup – RDS | — | $0.74 |
| Amazon Route 53 | — | $0.50 |
| Amazon SQS (0.8 M requests) | — | $0.32 |
| AWS KMS | — | $0.02 |
| AWS Lambda exam-worker, Amazon Cognito, data transfer out | — | $0.00 |
| AWS PrivateLink (row present, fields empty in the export) | — | $0.00 |
| NAT gateways | — | **removed** |
| **Total (calculator)** | **$668.00** | **$207.33** |
| + AWS PrivateLink, 2 interface endpoints × 2 AZs (calculator figure from the earlier optimized estimate, because this export's PrivateLink row was left empty) | | **+ $37.97** |
| **Final exam month** | **$668.00** | **$245.30** |

## 3. The three most expensive components

*(Assignment 2 design, normal month: $376.79.)*

1. **Amazon RDS for PostgreSQL Multi-AZ: $220.32 On-Demand (58%)**; $127.76/month + $668 upfront as a Reserved Instance. It is the only component sized for the 3,000-student peak rather than average load, and Multi-AZ doubles it by billing a standby instance and its storage in the second AZ. It is the price of RPO 0 and surviving an AZ loss.
2. **NAT gateways: $86.20 (23%)**, plus $14.60 for 4 public IPv4 addresses. A fixed hourly charge for two gateways (one per AZ), even though the Lambda sends almost no traffic through them.
3. **Application Load Balancer: $19.42 (5%).** Almost entirely the fixed hourly charge; the traffic uses only a fraction of one LCU.

## 4. Service choices compared with alternatives

### 4.1 Backend: Lambda vs ECS Fargate vs EC2 Auto Scaling

| | **Lambda (chosen)** | ECS Fargate (A2's first build) | EC2 Auto Scaling |
|---|---|---|---|
| Cost | **$3.50/month** for 8.64 M requests (x86, before Arm) | Two always-on tasks + extra tasks for the peak + an image registry | 2 instances minimum in 2 AZs + patching time |
| Performance | Scales per request in seconds; cold starts ~1–2 s; **capped by the account concurrency quota (default 10)** | Steady latency; new tasks take 1–3 min | Slowest to scale; needs pre-warming |
| Resilience | Runs across both private subnets automatically | Tasks spread across AZs | ASG across AZs |
| Effort | A zip file, no images or OS | Docker image pipeline, task definitions | AMIs, OS patching, agents |

### 4.2 Database for answers: RDS Multi-AZ vs Aurora Serverless v2 vs DynamoDB

| | **RDS PostgreSQL Multi-AZ (chosen)** | Aurora Serverless v2 | DynamoDB on-demand |
|---|---|---|---|
| Cost | $220.32/month On-Demand, or $127.76/month + $668 upfront Reserved (db.t4g.medium, Multi-AZ, 100 GB) | Billed per ACU-hour with a minimum per instance, ×2 for a Multi-AZ reader, plus I/O | Per request; no idle cost |
| Performance | Fixed size: must be resized before exams | Scales automatically within seconds | Single-digit ms at any scale; no connection limit |
| Resilience | Synchronous standby, failover ~1–2 min | Failover usually < 30 s; storage 6 copies across 3 AZs | Multi-AZ by default, no failover event |
| Effort | Plain PostgreSQL; no code change | Same SQL, new cluster | Rewrite the data model (no joins or reports) |

### 4.3 Private traffic: NAT gateway vs VPC endpoints

| | NAT gateway ×2 (A2) | **Interface endpoints for SQS + Secrets Manager (chosen)** |
|---|---|---|
| Cost | **$86.20 + $14.60 (4 public IPv4) = $100.80/month** | **$37.97 + $7.30 (2 public IPv4) = $45.27/month** |
| Performance | Extra hop out to the internet and back | Private path inside AWS |
| Resilience | Needs one per AZ | Endpoint interfaces in both AZs |
| Effort | Works for any destination | The Lambda must not need the internet: Cognito signing keys bundled at deploy time, debug RDS call removed |

### 4.4 5-year file retention: S3 Standard vs Intelligent-Tiering vs Glacier

| | S3 Standard only | Intelligent-Tiering | **Lifecycle: Standard → Standard-IA (30 d) → Glacier (365 d) → delete (5 y) (chosen)** |
|---|---|---|---|
| Cost (year 1, per month) | 480 GB × Standard price | Automatic tiering + a monitoring fee per object | **$7.77** (80 GB Standard $2.05 + 400 GB IA $5.72) |
| Retrieval | Instant | Instant | IA instant (with a per-GB fee); Glacier minutes to hours |
| Effort | None | None | One lifecycle rule |

The access pattern is predictable (read in the first weeks, then almost never), so a lifecycle rule beats Intelligent-Tiering's monitoring fee.

## 6. Feasibility verdict

| Target | Result |
|---|---|
| **Budget**: $1,000/month averaged |  **$284.63/month average** for the final design (28% of the budget); $340.09 as estimated in the calculator; even the unoptimized Assignment 2 design averages $380.26. |
| **Peak**: 3,000 starts in 5 min | Feasible **with two conditions**: raise the Lambda concurrency quota from the account default of 10 to at least 100, and run db.t4g.medium during exam weeks. |
| **RPO 5 min** | Synchronous Multi-AZ standby (no committed data lost on AZ failure); PITR logs every 5 min; unsaved answers kept in the browser |
| **RTO 1 h** | AZ failover in minutes; point-in-time restore of a 10 GB database well under 1 h |
| **Survive loss of one AZ** | ALB, Lambda, endpoints and RDS span both AZs |
| **Files kept 5 years** | S3 lifecycle (delete at 1,825 days) + AWS Backup 60 monthly snapshots |

## 7. Optimizations and savings

| # | Optimization | Before → after (per month) | Saving per year | Source |
|---|---|---|---:|---|
| 1 | NAT gateways → VPC interface endpoints (SQS + Secrets Manager, 2 AZs), 4 → 2 public IPv4 | $86.20 + $14.60 = $100.80 → $37.97 + $7.30 = $45.27 | **$666.36** | Calculator: NAT, Public IPv4 and AWS PrivateLink rows |
| 2 | RDS 1-year Reserved Instance (Partial Upfront) instead of On-Demand | $220.32 → $127.76 + $668 upfront | **$442.77** (= ($220.32 − $127.76) × 12 − $668) | Calculator: both RDS rows (100 GB) |
| 3 | CloudWatch Logs Standard → Infrequent Access | normal $6.02 → $3.01; exam $9.17 → $4.59 | **$39.27** | Calculator: CloudWatch rows; Standard rate $0.70/GB |
| | **Total** | $4,563.10 → $3,415.50 per year | **$1,147.60 (−25%)** | |

The Reserved Instance is 17% cheaper than On-Demand over the year ($2,201.07 vs $2,643.84, both calculator 12-month totals).
