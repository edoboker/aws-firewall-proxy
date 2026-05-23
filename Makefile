POWERSHELL := powershell.exe
PACKER_WIN_PATH := C:\Windows\Sysnative\packer.exe
TERRAFORM_WIN_PATH := C:\Windows\Sysnative\terraform.exe

AWS_REGION ?= eu-north-1
DNS_RESOLVERS ?= 169.254.169.253,1.1.1.1,8.8.8.8
DNS_QUERIES_PER_SNI ?= 3
PACKER_PROXY_INSTANCE_TYPE ?= c6i.large
PACKER_WORKLOAD_INSTANCE_TYPE ?= t3.small

PACKER_BUILD_INFRA_DIR := packer/build-infra
PACKER_PROXY_DIR := packer/nginx-proxy
PACKER_WORKLOAD_DIR := packer/workload
TERRAFORM_DIR := terraform

BUILD_INFRA_APPLY_ARGS ?=
BUILD_INFRA_DESTROY_ARGS ?=
PACKER_PROXY_BUILD_ARGS ?=
PACKER_WORKLOAD_BUILD_ARGS ?=
TERRAFORM_PLAN_ARGS ?=
TERRAFORM_APPLY_ARGS ?=
TERRAFORM_DESTROY_ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help \
	build-infra-init build-infra-apply build-infra-destroy \
	packer-validate-proxy packer-validate-workload \
	packer-build-proxy packer-build-workload packer-build-all \
	terraform-init terraform-plan terraform-apply terraform-destroy \
	deploy-all

help:
	@echo Targets:
	@echo   make build-infra-apply            Deploy the packer build VPC/subnet
	@echo   make packer-build-proxy           Build the proxy AMI with OpenResty/Lua/C module
	@echo   make packer-build-workload        Build the workload AMI
	@echo   make packer-build-all             Build both AMIs
	@echo   make terraform-apply              Deploy the full AWS stack from terraform/
	@echo   make deploy-all                   Build infra, both AMIs, then terraform apply
	@echo.
	@echo Useful variables:
	@echo   AWS_REGION=$(AWS_REGION)
	@echo   DNS_RESOLVERS=$(DNS_RESOLVERS)
	@echo   DNS_QUERIES_PER_SNI=$(DNS_QUERIES_PER_SNI)
	@echo   PACKER_PROXY_INSTANCE_TYPE=$(PACKER_PROXY_INSTANCE_TYPE)
	@echo   PACKER_WORKLOAD_INSTANCE_TYPE=$(PACKER_WORKLOAD_INSTANCE_TYPE)
	@echo   BUILD_INFRA_APPLY_ARGS=-auto-approve
	@echo   TERRAFORM_APPLY_ARGS=-auto-approve
	@echo   PACKER_PROXY_BUILD_ARGS=-force
	@echo.
	@echo Example:
	@echo   make deploy-all BUILD_INFRA_APPLY_ARGS=-auto-approve TERRAFORM_APPLY_ARGS=-auto-approve

build-infra-init:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' init"

build-infra-apply:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' apply $(BUILD_INFRA_APPLY_ARGS)"

build-infra-destroy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' destroy $(BUILD_INFRA_DESTROY_ARGS)"

packer-validate-proxy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "& '$(PACKER_WIN_PATH)' validate '$(PACKER_PROXY_DIR)'"

packer-validate-workload:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "& '$(PACKER_WIN_PATH)' validate '$(PACKER_WORKLOAD_DIR)'"

packer-build-proxy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(PACKER_WIN_PATH)' init '$(PACKER_PROXY_DIR)'; $$repoRoot = (Get-Location).Path.Replace('\', '/'); $$gitSha = (& git -c ('safe.directory=' + $$repoRoot) rev-parse --short HEAD).Trim(); $$packerVpcId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw vpc_id).Trim(); $$packerSubnetId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw subnet_id).Trim(); & '$(PACKER_WIN_PATH)' build -var ('aws_region=$(AWS_REGION)') -var ('instance_type=$(PACKER_PROXY_INSTANCE_TYPE)') -var ('git_sha=' + $$gitSha) -var ('dns_resolvers=$(DNS_RESOLVERS)') -var ('dns_queries_per_sni=$(DNS_QUERIES_PER_SNI)') -var ('packer_vpc_id=' + $$packerVpcId) -var ('packer_subnet_id=' + $$packerSubnetId) $(PACKER_PROXY_BUILD_ARGS) '$(PACKER_PROXY_DIR)'"

packer-build-workload:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(PACKER_WIN_PATH)' init '$(PACKER_WORKLOAD_DIR)'; $$repoRoot = (Get-Location).Path.Replace('\', '/'); $$gitSha = (& git -c ('safe.directory=' + $$repoRoot) rev-parse --short HEAD).Trim(); $$packerVpcId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw vpc_id).Trim(); $$packerSubnetId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw subnet_id).Trim(); & '$(PACKER_WIN_PATH)' build -var ('aws_region=$(AWS_REGION)') -var ('instance_type=$(PACKER_WORKLOAD_INSTANCE_TYPE)') -var ('git_sha=' + $$gitSha) -var ('packer_vpc_id=' + $$packerVpcId) -var ('packer_subnet_id=' + $$packerSubnetId) $(PACKER_WORKLOAD_BUILD_ARGS) '$(PACKER_WORKLOAD_DIR)'"

packer-build-all: packer-build-proxy packer-build-workload

terraform-init:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init"

terraform-plan:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' plan $(TERRAFORM_PLAN_ARGS)"

terraform-apply:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' apply $(TERRAFORM_APPLY_ARGS)"

terraform-destroy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' destroy $(TERRAFORM_DESTROY_ARGS)"

deploy-all: build-infra-apply packer-build-all terraform-apply
