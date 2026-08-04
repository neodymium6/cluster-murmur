set shell := ["bash", "-euo", "pipefail", "-c"]

# Show available recipes.
default:
  @just --list

# Initialize Git when needed and install repository hooks.
init:
  if ! git rev-parse --git-dir >/dev/null 2>&1; then git init -b main; fi
  pre-commit install --install-hooks

# Format repository-owned files.
fmt:
  mix format
  nix fmt -- flake.nix

# Run all checks available for the current bootstrap stage.
check:
  pre-commit run --all-files
  mix format --check-formatted
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix test
  nix flake check .
  nix flake check --no-build --all-systems .

# CI alias.
ci: check

# Update pinned development-environment inputs.
update:
  nix flake update
