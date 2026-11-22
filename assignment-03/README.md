# DSO303 Assignment 3 – Cost, Feasibility and Resilience Analysis

The Assignment 2 online exam platform, re-costed for **Asia Pacific (Singapore), ap-southeast-1**, with cost optimizations, a single-point-of-failure review, and failure and load test scenarios.

## Summary

- **Load profiles:** 10 normal months (300–500 concurrent users) and 2 exam months (peak: 3,000 students starting one exam within 5 minutes).
- **Design:** CloudFront + WAF → Application Load Balancer → API Lambda in two private subnets → RDS PostgreSQL Multi-AZ, with S3 presigned uploads, SQS + worker Lambda, SES, and AWS Backup.
- **Cost (AWS Pricing Calculator, 21 Nov 2026):** the two calculator estimates (exported in `evidence/`) total **$281.22/month (normal)** and **$300.43/month (exam)**, plus **$668 upfront** once a year for the Reserved database.

| | Assignment 2 design (all On-Demand) | As estimated in the calculator | **Final design** (+ VPC endpoints) |
|---|---:|---:|---:|
| Normal month | $376.79 | $281.22 + $55.67 upfront share = $336.89 | **$281.36** |
| Exam month | $397.58 | $300.43 + $55.67 upfront share = $356.10 | **$300.97** |
| **Annual total (10 normal + 2 exam)** | $4,563.10 | $4,081.06 | **$3,415.50** |
| Average per month (budget $1,000) | $380.26 (38.0%) | $340.09 (34.0%) | **$284.63 (28.5%)** |
| **Cost per student per year** (8,000) | $0.57 | $0.51 | **$0.43** |


## Feasibility verdict

| Target | Verdict |
|---|---|
| Budget: $1,000/month averaged | **$284.63/month** for the final design, 28.5% of the budget |
| Peak: 3,000 starts in 5 min |  Feasible **with two conditions**: Lambda concurrency quota raised from the default 10 to ≥ 100, and db.t4g.medium during exam weeks |
| RPO 5 min | Synchronous Multi-AZ standby + point-in-time recovery; unsaved answers kept in the browser |
| RTO 1 hour | AZ failover in minutes; point-in-time restore well under 1 hour |
| Survive loss of one AZ | Load balancer, Lambda, endpoints and database span ap-southeast-1a and 1b |
| Files kept 5 years | S3 lifecycle (Standard → IA → archive → delete at 5 years) + AWS Backup monthly snapshots |

**Feasiblility** The platform uses under 30% of the budget, provided the concurrency quota and the exam-time database size are in place before exams.

## Optimizations (measured in the calculator)

| Optimization | Saving per year |
|---|---:|
| NAT gateways → VPC interface endpoints | $666.36 |
| RDS 1-year Reserved Instance (17% cheaper than On-Demand over the year) | $442.77 |
| CloudWatch Logs → Infrequent Access log class | $39.27 |
| **Total** | **$1,147.60 (−25%)** |

## AWS Pricing Calculator

Both exports enter the database as a 1-year Reserved Instance (Partial Upfront, $668) and CloudWatch with Infrequent Access logs. The Assignment 2 (On-Demand) and final (VPC endpoint) figures are derived from calculator rows, as shown in `cost-report.md` sections 2.3 and 7.

**Conclusion**

The platform is affordable in Singapore. The final design costs $3,415.50 a year (about $285 a month), which is 28.5% of the budget or $0.43 per student per year. Three optimizations (VPC endpoints instead of NAT, a Reserved database, and cheaper logs) save $1,147.60 a year (−25%) without reducing resilience.