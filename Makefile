SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help ci smolvm smolvm-pack smolvm-clean smolvm-exec smolvm-preflight smolvm-verify check-jactionlint check-bash check-commits check-dclint check-dockerfmt check-editorconfig check-gitleaks check-hadolint check-markdown check-mise check-shfmt check-zizmor format format-shfmt format-dockerfmt format-dclint hooks release

help: ## Show this help.
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

ci: ## Run every check.
	scripts/ci.sh

smolvm: ## Run the checks inside a smolvm microVM, local or remote.
	scripts/smolvm.sh

smolvm-pack: ## Build the cached smolvm pack for the microVM.
	smol/pack-build.sh

smolvm-clean: ## Remove this checkout's smolvm cache and machines after confirmation (ARGS='...').
	scripts/smolvm-clean.sh $(ARGS)

smolvm-exec: ## Run a command inside the microVM, local or remote (ARGS='...').
	@scripts/smolvm-exec.sh "$(ARGS)"

smolvm-preflight: ## Probe whether this host is ready for the smolvm microVM.
	smol/preflight.sh

smolvm-verify: ## Verify the isolation of the microVM from inside and outside the guest.
	smol/verify.sh

check-jactionlint: ## Check the GitHub Actions workflows with jactionlint.
	scripts/check-jactionlint.sh

check-bash: ## Check every bash file with shellcheck.
	scripts/check-bash.sh

check-commits: ## Check the commit history with cocogitto.
	scripts/check-commits.sh

check-dclint: ## Check the Docker Compose files with dclint.
	scripts/check-dclint.sh

check-dockerfmt: ## Check the Dockerfile and Containerfile files with dockerfmt.
	scripts/check-dockerfmt.sh

check-editorconfig: ## Check the files against EditorConfig rules.
	scripts/check-editorconfig.sh

check-gitleaks: ## Scan the repository for secrets with gitleaks.
	scripts/check-gitleaks.sh

check-hadolint: ## Check the Dockerfile and Containerfile files with hadolint.
	scripts/check-hadolint.sh

check-markdown: ## Check every Markdown file with markdownlint-cli2.
	scripts/check-markdown.sh

check-mise: ## Check the mise config file when mise is available.
	scripts/check-mise.sh

check-shfmt: ## Check the bash file format with shfmt.
	scripts/check-shfmt.sh

check-zizmor: ## Check the GitHub Actions workflows with zizmor.
	scripts/check-zizmor.sh

format: ## Apply every formatter.
	scripts/format.sh

format-shfmt: ## Format every bash file with shfmt.
	scripts/format-shfmt.sh

format-dockerfmt: ## Format the Dockerfile and Containerfile files with dockerfmt.
	scripts/format-dockerfmt.sh

format-dclint: ## Fix the Docker Compose files with dclint.
	scripts/format-dclint.sh

hooks: ## Install the git hooks in .githook.
	git config core.hooksPath .githook
	chmod +x .githook/pre-commit .githook/pre-push

release: ## Bump the version and update the changelog in the sandbox when smolvm is available.
	scripts/release.sh $(ARGS)
