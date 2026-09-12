# AWS Infrastructure via Terraform + GitHub Actions

Provisions in **us-east-1**:
- VPC with public + private subnets across 2 AZs, IGW, NAT Gateway
- EC2 (Amazon Linux 2023, t3.micro) in public subnet
- RDS PostgreSQL 17 (db.t3.micro) in private subnet
- Lambda function that lists all AWS resources in the account

---

## Repository Structure

```
.
├── terraform/
│   ├── main.tf        # Provider + backend config
│   ├── variables.tf   # All input variables
│   ├── vpc.tf         # VPC, subnets, IGW, NAT, route tables
│   ├── ec2.tf         # EC2 instance + security group
│   ├── rds.tf         # RDS PostgreSQL + subnet group
│   ├── lambda.tf      # Lambda + IAM role + security group
│   └── outputs.tf     # Output values
├── src/
│   └── lambda_function.py   # Lists EC2, S3, RDS, Lambda, VPCs, IAM, etc.
├── .github/
│   └── workflows/
│       └── terraform.yml    # CI/CD pipeline
└── .gitignore
```

---

## One-Time Setup

### 1. Create GitHub Repository

Push this code to `https://github.com/savenbuan2025/<repo-name>`:

```bash
git init
git add .
git commit -m "Initial infrastructure"
git remote add origin https://github.com/savenbuan2025/<repo-name>.git
git push -u origin main
```

### 2. Create AWS IAM User for GitHub Actions

In AWS Console → IAM → Users → Create user:
- Name: `github-actions-terraform`
- Attach policies: `AdministratorAccess` (or a scoped policy for your resources)
- Create Access Key → save **Access Key ID** and **Secret Access Key**

### 3. Add GitHub Secrets

Go to your GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret Name            | Value                                      |
|------------------------|--------------------------------------------|
| `AWS_ACCESS_KEY_ID`    | IAM user access key ID                     |
| `AWS_SECRET_ACCESS_KEY`| IAM user secret access key                 |
| `TF_STATE_BUCKET`      | A globally unique S3 bucket name, e.g. `myproject-tfstate-123456` |
| `DB_PASSWORD`          | Strong password for RDS PostgreSQL         |

### 4. Push to main

The pipeline runs automatically on every push to `main`:
- **Pull Requests** → runs `plan` only (no apply)
- **Push to main** → runs `plan` then `apply`

---

## Invoking the Lambda

```bash
# List all resources (returns JSON)
aws lambda invoke \
  --function-name myproject-list-resources \
  --region us-east-1 \
  output.json && cat output.json
```

---

## Useful Commands (local)

```bash
# Init with your state bucket
terraform -chdir=terraform init \
  -backend-config="bucket=YOUR_BUCKET" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1"

# Plan
terraform -chdir=terraform plan -var="db_password=YOUR_PASSWORD"

# Apply
terraform -chdir=terraform apply -var="db_password=YOUR_PASSWORD"

# Destroy
terraform -chdir=terraform destroy -var="db_password=YOUR_PASSWORD"
```

---

## Notes

- **RDS PostgreSQL version**: If `17.2` is unavailable, run:
  ```bash
  aws rds describe-db-engine-versions --engine postgres \
    --query "DBEngineVersions[?starts_with(EngineVersion,'17')].EngineVersion"
  ```
  Then update `engine_version` in `terraform/rds.tf`.
- **SSH access**: EC2 SG currently allows `0.0.0.0/0` on port 22 — restrict to your IP in production.
- **NAT Gateway** incurs hourly + data transfer costs (~$32/month). Remove it if Lambda doesn't need internet.
