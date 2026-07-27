# infra/ — Terraform

There is no `main.tf` on purpose. Terraform merges **all** `.tf` files in this
directory at plan time — filenames are just for humans — so the config is split
by concern instead of one long file:

| File | Contains |
|------|----------|
| `versions.tf`  | Terraform + provider version constraints (state is local) |
| `providers.tf` | AWS provider (region, profile, default tags) |
| `variables.tf` | All input variables |
| `data.tf`      | AMI / default-VPC / subnet lookups + `locals` |
| `network.tf`   | Security group and its rules |
| `instance.tf`  | EC2 Windows instance + its IAM role/instance profile |
| `lambda.tf`    | `windrose-bot` Lambda + IAM role + zip packaging |
| `apigw.tf`     | HTTP API Gateway → Lambda |
| `ssm.tf`       | Discord secrets/config in SSM Parameter Store |
| `outputs.tf`   | Outputs (instance ID, Discord interactions URL, etc.) |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then fill in Discord values
../scripts/build_lambda.sh                      # build the Lambda zip first
terraform init
terraform apply
```

`terraform.tfvars` and `terraform.tfstate*` are gitignored. See `docs/RUNBOOK.md`
for the full end-to-end setup.
