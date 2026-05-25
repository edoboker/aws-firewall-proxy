POWERSHELL := powershell.exe
PACKER_WIN_PATH := C:\Windows\Sysnative\packer.exe
TERRAFORM_WIN_PATH := C:\Windows\Sysnative\terraform.exe
PYTHON ?= python
VENV_DIR := .venv
VENV_PYTHON := $(VENV_DIR)\Scripts\python.exe

AWS_REGION ?= eu-north-1
PACKER_PROXY_INSTANCE_TYPE ?= c6i.large
PACKER_WORKLOAD_INSTANCE_TYPE ?= t3.small
PACKER_BIND_INSTANCE_TYPE ?= t3.small
PACKER_BIND_ALLOW_QUERY_CIDR ?= 10.0.0.0/16
PACKER_BIND_MIN_CACHE_TTL ?= 90
PACKER_BIND_STALE_ANSWER_TTL ?= 30

PACKER_BUILD_INFRA_DIR := terraform/packer-bootstrap
PACKER_PROXY_DIR := packer/nginx-proxy
PACKER_WORKLOAD_DIR := packer/workload
PACKER_BIND_DIR := packer/bind-dns
TERRAFORM_DIR := terraform
TERRAFORM_BOOTSTRAP_DIR := terraform/bootstrap

BOOTSTRAP_APPLY_ARGS ?=
BUILD_INFRA_APPLY_ARGS ?=
BUILD_INFRA_DESTROY_ARGS ?=
PACKER_PROXY_BUILD_ARGS ?=
PACKER_WORKLOAD_BUILD_ARGS ?=
PACKER_BIND_BUILD_ARGS ?=
TERRAFORM_PLAN_ARGS ?=
TERRAFORM_APPLY_ARGS ?=
TERRAFORM_DESTROY_ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help \
	setup test test-offline \
	bootstrap-apply \
	build-infra-init build-infra-apply build-infra-destroy \
	packer-validate-proxy packer-validate-workload packer-validate-bind \
	packer-build-proxy packer-build-workload packer-build-bind packer-build-all \
	terraform-init terraform-plan terraform-apply terraform-destroy \
	deploy-all

help:
	@echo Targets:
	@echo   make setup                        Create .venv and install local Python packages
	@echo   make test                         Run pytest -v tests via the repo-root .venv (live tests skip without a deployed stack)
	@echo   make test-offline                 Run only the offline tests (no AWS / deployed stack needed)
	@echo   make bootstrap-apply              Create the S3 remote-state bucket (one-time)
	@echo   make build-infra-apply            Deploy the packer build VPC/subnet
	@echo   make packer-build-proxy           Build the proxy AMI with OpenResty/Lua/C module
	@echo   make packer-build-workload        Build the workload AMI
	@echo   make packer-build-bind            Build the BIND9 shared DNS cache AMI
	@echo   make packer-build-all             Build all AMIs
	@echo   make terraform-apply              Deploy the full AWS stack from terraform/
	@echo   make deploy-all                   Build infra, all AMIs, then terraform apply
	@echo.
	@echo Useful variables:
	@echo   AWS_REGION=$(AWS_REGION)
	@echo   PACKER_PROXY_INSTANCE_TYPE=$(PACKER_PROXY_INSTANCE_TYPE)
	@echo   PACKER_WORKLOAD_INSTANCE_TYPE=$(PACKER_WORKLOAD_INSTANCE_TYPE)
	@echo   PACKER_BIND_INSTANCE_TYPE=$(PACKER_BIND_INSTANCE_TYPE)
	@echo   PACKER_BIND_ALLOW_QUERY_CIDR=$(PACKER_BIND_ALLOW_QUERY_CIDR)
	@echo   PACKER_BIND_MIN_CACHE_TTL=$(PACKER_BIND_MIN_CACHE_TTL)
	@echo   PACKER_BIND_STALE_ANSWER_TTL=$(PACKER_BIND_STALE_ANSWER_TTL)
	@echo   BUILD_INFRA_APPLY_ARGS=-auto-approve
	@echo   TERRAFORM_APPLY_ARGS=-auto-approve
	@echo   PACKER_PROXY_BUILD_ARGS=-force
	@echo   PACKER_BIND_BUILD_ARGS=-force
	@echo.
	@echo Example:
	@echo   make deploy-all BUILD_INFRA_APPLY_ARGS=-auto-approve TERRAFORM_APPLY_ARGS=-auto-approve

setup:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Test-Path '$(VENV_PYTHON)')) { & '$(PYTHON)' -m venv '$(VENV_DIR)' }; & '$(VENV_PYTHON)' -m pip install -e '.[test,benchmark]'"

test:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Test-Path '$(VENV_PYTHON)')) { throw 'Virtualenv missing. Run `make setup` first.' }; & '$(VENV_PYTHON)' -m pytest -v tests"

# The offline subset: schema + terraform static checks. No AWS, no deployed stack.
test-offline:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Test-Path '$(VENV_PYTHON)')) { throw 'Virtualenv missing. Run `make setup` first.' }; & '$(VENV_PYTHON)' -m pytest -v tests/test_appconfig_policy_schema.py tests/test_terraform_static.py"

# One-time: create the S3 bucket that holds remote state for the other stacks.
# Keeps its own state local (it is the stack that creates the state bucket).
bootstrap-apply:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_BOOTSTRAP_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_BOOTSTRAP_DIR)' apply $(BOOTSTRAP_APPLY_ARGS)"

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

packer-validate-bind:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "& '$(PACKER_WIN_PATH)' validate '$(PACKER_BIND_DIR)'"

packer-build-proxy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(PACKER_WIN_PATH)' init '$(PACKER_PROXY_DIR)'; $$repoRoot = (Get-Location).Path.Replace('\', '/'); $$gitSha = (& git -c ('safe.directory=' + $$repoRoot) rev-parse --short HEAD).Trim(); $$packerVpcId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw vpc_id).Trim(); $$packerSubnetId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw subnet_id).Trim(); & '$(PACKER_WIN_PATH)' build -var ('aws_region=$(AWS_REGION)') -var ('instance_type=$(PACKER_PROXY_INSTANCE_TYPE)') -var ('git_sha=' + $$gitSha) -var ('packer_vpc_id=' + $$packerVpcId) -var ('packer_subnet_id=' + $$packerSubnetId) $(PACKER_PROXY_BUILD_ARGS) '$(PACKER_PROXY_DIR)'"

packer-build-workload:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(PACKER_WIN_PATH)' init '$(PACKER_WORKLOAD_DIR)'; $$repoRoot = (Get-Location).Path.Replace('\', '/'); $$gitSha = (& git -c ('safe.directory=' + $$repoRoot) rev-parse --short HEAD).Trim(); $$packerVpcId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw vpc_id).Trim(); $$packerSubnetId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw subnet_id).Trim(); & '$(PACKER_WIN_PATH)' build -var ('aws_region=$(AWS_REGION)') -var ('instance_type=$(PACKER_WORKLOAD_INSTANCE_TYPE)') -var ('git_sha=' + $$gitSha) -var ('packer_vpc_id=' + $$packerVpcId) -var ('packer_subnet_id=' + $$packerSubnetId) $(PACKER_WORKLOAD_BUILD_ARGS) '$(PACKER_WORKLOAD_DIR)'"

packer-build-bind:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(PACKER_WIN_PATH)' init '$(PACKER_BIND_DIR)'; $$repoRoot = (Get-Location).Path.Replace('\', '/'); $$gitSha = (& git -c ('safe.directory=' + $$repoRoot) rev-parse --short HEAD).Trim(); $$packerVpcId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw vpc_id).Trim(); $$packerSubnetId = (& '$(TERRAFORM_WIN_PATH)' -chdir='$(PACKER_BUILD_INFRA_DIR)' output -raw subnet_id).Trim(); & '$(PACKER_WIN_PATH)' build -var ('aws_region=$(AWS_REGION)') -var ('instance_type=$(PACKER_BIND_INSTANCE_TYPE)') -var ('git_sha=' + $$gitSha) -var ('packer_vpc_id=' + $$packerVpcId) -var ('packer_subnet_id=' + $$packerSubnetId) -var ('bind_allow_query_cidr=$(PACKER_BIND_ALLOW_QUERY_CIDR)') -var ('bind_min_cache_ttl=$(PACKER_BIND_MIN_CACHE_TTL)') -var ('bind_stale_answer_ttl=$(PACKER_BIND_STALE_ANSWER_TTL)') $(PACKER_BIND_BUILD_ARGS) '$(PACKER_BIND_DIR)'"

packer-build-all: packer-build-proxy packer-build-workload packer-build-bind

terraform-init:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init"

terraform-plan:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' plan $(TERRAFORM_PLAN_ARGS)"

terraform-apply:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' apply $(TERRAFORM_APPLY_ARGS)"

terraform-destroy:
	@"$(POWERSHELL)" -NoProfile -ExecutionPolicy Bypass -Command "$$env:AWS_REGION = '$(AWS_REGION)'; $$env:TF_VAR_aws_region = '$(AWS_REGION)'; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' init; & '$(TERRAFORM_WIN_PATH)' -chdir='$(TERRAFORM_DIR)' destroy $(TERRAFORM_DESTROY_ARGS)"

deploy-all: build-infra-apply packer-build-all terraform-apply
