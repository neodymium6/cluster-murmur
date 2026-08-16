# Project Guidance

This repository is intended for public release. Keep source, tests, examples,
documentation, and history environment-neutral.

## Safety and privacy

- Never commit credentials, private keys, access tokens, webhook URLs, real
  internal domains, private IP addresses, cluster names, hardware identifiers,
  private endpoints, or personal contact details.
- Use RFC 5737 addresses, `example.com`, `example.invalid`, and clearly fake
  identifiers in examples and tests.
- Keep real deployment overlays, encrypted Secrets, kubeconfigs, endpoint
  inventories, persona prompts, and channel routing in the operator's private
  infrastructure repository when they reveal private details.
- Do not deploy this project, publish Discord messages, or connect it to live
  infrastructure without explicit approval for the exact environment and
  revision.

## Product boundary

- Preserve the separation between read-only observation and conversation
  orchestration.
- Do not add generic shell, SSH, `kubectl`, SQL, arbitrary PromQL, or arbitrary
  HTTP passthrough capabilities.
- Keep factual event decisions in application code. The LLM may invent harmless
  fictional dialogue, but must not contradict supplied operational facts or
  claim real capabilities and side effects.
- Keep all conversations bounded by turns, participants, duration, LLM calls,
  cooldowns, and an explicit no-reply path.
- Treat observation data and generated prompts as potentially sensitive. Apply
  redaction, field allowlists, response-size limits, and safe logging defaults.

## Development

- Run `just check` before committing.
- Use Conventional Commit messages.
- Write code, comments, commits, and repository documentation in English.
- Record material architecture decisions in `docs/adr/`.
