# Copilot instructions — HA experiments repo

This repository is a personal sandbox for **Home Assistant** blueprints and config experiments. It is **not** a Home Assistant integration / custom component / Python package.

## Repository layout

- `blueprints/automation/` — automation blueprints authored in this repo
- `blueprints/automation/references/` — upstream blueprints kept for reference only (do **not** edit)
- Other blueprint domains (`blueprints/script/`, `blueprints/template/`) can be added under `blueprints/<domain>/` when needed; nothing exists there yet
- `.ha-validate/` — minimal HA config used by the local Docker validator; the validator bind-mounts `blueprints/automation/` into `.ha-validate/blueprints/automation/local/` at runtime
- `docs/validating-blueprints.md` — full validation workflow
- `.github/instructions/` — task-specific instructions auto-loaded for matching files

## Working principles

- **Edit only blueprints under `blueprints/automation/`** (and other top-level blueprint folders). Files under `blueprints/automation/references/` are upstream copies for reference and must stay byte-identical to their source.
- **Always preserve license attribution** in headers when adapting from upstream blueprints. The upstream blueprints in `references/` are MIT-licensed; credit both the project and the URL.
- **Validate after every blueprint edit** by running `bash scripts/validate-blueprints.sh` (or the VS Code task *“Validate blueprints”*). The same script runs in CI via [.github/workflows/validate.yml](workflows/validate.yml). See [docs/validating-blueprints.md](../docs/validating-blueprints.md) for the full breakdown.
- **No host Python.** Both validation layers run inside the HA Docker image, so only `bash` + `docker` are required on the host. Don't add a top-level `requirements.txt`, `pyproject.toml`, or virtualenv unless explicitly asked.
- **Shell scripts use bash, not PowerShell.** On Windows the user runs them from WSL (or Git Bash); Docker Desktop's WSL integration provides `docker` inside WSL.
## Blueprint-specific guidance

When creating, modifying, or reviewing files under `blueprints/**/*.yaml`, the file-pattern instructions in [.github/instructions/blueprints.instructions.md](instructions/blueprints.instructions.md) auto-attach. They cover the HA blueprint schema, selector pitfalls, the `!input`/template interaction, and the per-edit validation checklist.

## Out of scope

- Full Home Assistant custom-integration development (Python, manifest.json, hassfest, etc.). If asked, ask the user to confirm before scaffolding — this repo isn't currently structured for it.
- Frontend/Lovelace card development.
