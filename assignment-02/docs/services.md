# Service documentation

| Service | Role | Alternative | Connects to |
|---|---|---|---|
| **Route 53** | DNS for the exam website | External DNS provider: Route 53 can point the domain straight at CloudFront for free | CloudFront |
| **CloudFront** | Front door: serves the web page and forwards `/api` calls | Users going straight to the load balancer: CloudFront caches the page close to students and hides the backend | Route 53, WAF, S3 (frontend), ALB |
| **AWS WAF** | Blocks attacks such as SQL injection and request floods | Security groups only: they cannot inspect web requests | CloudFront |
| **S3 (frontend)** | Stores the exam web page | Web server on EC2: S3 is cheaper and needs no maintenance | CloudFront |
| **Cognito** | Sign-in with roles (student, tutor, admin) | Own login system: Cognito handles passwords and tokens securely | Web page, API Lambda |
| **VPC + subnets** | Private network across two AZs | Default VPC: it has only public subnets, so the database could not be kept private | All network resources |
| **Internet Gateway** | Internet access for the public subnets | None: required for a public load balancer | ALB, NAT gateways |
| **NAT Gateway (×2)** | Lets private resources reach the internet outbound only | One shared NAT: one per AZ keeps working if the other AZ fails | Private subnets |
| **Security groups** | Firewall rules between tiers | Network ACLs: security groups can allow traffic by group, e.g. "database accepts only the API" | ALB, API Lambda, RDS |
| **Application Load Balancer** | Spreads API requests across both AZs | Network Load Balancer: it cannot call Lambda or route web paths | CloudFront, API Lambda |
| **Lambda (exam-api)** | Runs the exam API: start exam, autosave, submit, upload links | ECS Fargate: Lambda needs no containers or servers and costs almost nothing between exams | ALB, RDS, SQS, S3, Secrets Manager |
| **Lambda (exam-worker)** | Background jobs: marks MCQs and notifies the tutor about uploads | Always-on worker server: Lambda runs only when there is work | SQS, SES |
| **RDS PostgreSQL (Multi-AZ)** | Stores exams, attempts and autosaved answers | DynamoDB: relational tables suit exam data, and Multi-AZ keeps a live copy in the second AZ | API Lambda, Secrets Manager, AWS Backup |
| **Secrets Manager** | Keeps the database password safe | Password in code: Secrets Manager stores it encrypted and rotates it | RDS, API Lambda |
| **S3 (submissions)** | Stores uploaded assignments; moves old files to cheaper storage and deletes them after 5 years | EBS disk: S3 is cheaper and more durable, and students upload to it directly | Web page, API Lambda, SQS |
| **AWS Backup** | Keeps database backups for 5 years | RDS automatic backups only: they last at most 35 days | RDS |
| **SQS + dead-letter queue** | Queues marking and upload jobs | SNS: SQS holds jobs until processed and retries failures | API Lambda, S3, worker Lambda |
| **SES** | Sends result and tutor emails | Own mail server: SES is managed and reliable | Worker Lambda |
| **CloudWatch** | Logs, metrics and alarms | Self-hosted monitoring (Grafana): CloudWatch is built in | All services |
| **IAM** | Gives each component only the permissions it needs | Access keys in code: roles are safer and need no stored keys | All services |