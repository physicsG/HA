# HA — Home Assistant experiments

[![Blueprint test suite](https://github.com/physicsG/HA/actions/workflows/validate.yml/badge.svg)](https://github.com/physicsG/HA/actions/workflows/validate.yml)

Personal repository for experimenting with Home Assistant blueprints, automations, and config.

## Structure

```
blueprints/
└── automation/
    ├── styrbar_dim_to_warm.yaml      # main blueprint (this repo)
    └── references/                    # upstream blueprints kept for reference (MIT)
        ├── ikea_e2001_e2002.yaml      # EPMatt/awesome-ha-blueprints
        └── dim_to_warm.yaml           # robblids/ha-dim-to-warm
.ha-validate/                          # staging dir used by the local HA validator
```

> Other blueprint domains (`script/`, `template/`) can be added under `blueprints/<domain>/` when needed — the validator picks them up automatically.

## Blueprint: `styrbar_dim_to_warm`

Combines an **IKEA E2001/E2002 STYRBAR** remote (Zigbee2MQTT) with a **Hue-style "dim to warm"** color-temperature curve. Brightness up/down on the remote (and optionally external brightness changes from the HA UI / voice / other automations) automatically shift the lights' color temperature between a warm minimum and a cool maximum.

See the header comment in [blueprints/automation/styrbar_dim_to_warm.yaml](blueprints/automation/styrbar_dim_to_warm.yaml) for full details.

### Required helpers (create both before importing)

In Home Assistant: *Settings → Devices & Services → Helpers → Create helper → Text* (twice):

| Helper | Purpose |
|---|---|
| `input_text` (e.g. `styrbar_dtw_last_event`)   | Stores last button press for double-press detection |
| `input_text` (e.g. `styrbar_dtw_last_command`) | Stores last command issued, used to suppress feedback echoes |

Both are exposed as blueprint inputs, so you can use one helper per remote/light-group instance.

### Importing into Home Assistant

1. **Manual file copy** — drop the YAML into `<ha-config>/blueprints/automation/local/`, then *Settings → Automations & Scenes → Blueprints* will list it.
2. **My HA blueprint import** — once this repo is on a git host, use the My HA "Import Blueprint" link with the raw URL.

## Validating blueprints locally

A single bash script does everything (YAML+`!input` parse, then HA `check_config` in Docker):

```bash
bash scripts/validate-blueprints.sh                 # all blueprints, all layers
bash scripts/validate-blueprints.sh --pull          # force docker pull first
bash scripts/validate-blueprints.sh blueprints/automation/styrbar_dim_to_warm.yaml
```

Both layers (YAML+`!input` parse and HA `check_config`) run inside the official `ghcr.io/home-assistant/home-assistant:stable` image, so the only host requirements are `bash` and `docker` — no host Python, no venv.

The same script powers:

- **VS Code tasks** — *Terminal → Run Task → “Validate blueprints”* (and *Validate current blueprint*), see [.vscode/tasks.json](.vscode/tasks.json).
- **GitHub Actions** — [.github/workflows/validate.yml](.github/workflows/validate.yml) runs a multi-job suite on every PR (`yaml-syntax`, `ha-check-config` against `:stable` and `:beta`, `yamllint`) plus a `test-suite` aggregate gate suitable for branch-protection.

On Windows, run from WSL (`bash`) or Git Bash. Full details, per-layer manual equivalents, and the full CI breakdown in [docs/validating-blueprints.md](docs/validating-blueprints.md).

## Editor setup (VS Code)

Open the repo in VS Code and accept the *\u201cWorkspace recommendations\u201d* notification \u2014 it installs:

- **Red Hat YAML** ([`redhat.vscode-yaml`](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml)) \u2014 inline YAML errors, format-on-save, schema-aware autocomplete. Pre-configured in [.vscode/settings.json](.vscode/settings.json) with HA's custom tags (`!input`, `!secret`, `!include\u2026`) and a best-effort HA schema from SchemaStore.
- **EditorConfig** ([`editorconfig.editorconfig`](https://marketplace.visualstudio.com/items?itemName=EditorConfig.EditorConfig)) \u2014 enforces 2-space indent / LF / final newline / trim trailing whitespace per [.editorconfig](.editorconfig).
- **ShellCheck** ([`timonwong.shellcheck`](https://marketplace.visualstudio.com/items?itemName=timonwong.shellcheck)) \u2014 lints `scripts/*.sh` on save.

If the SchemaStore HA schema flags a legit blueprint construct as an error, disable validation for that one file by adding this as the very first line:

```yaml
# yaml-language-server: $schema=
```

Once the extensions are in, hit **Ctrl+Shift+B \u2192 Run Test Task** to fire the full validator (same script CI runs).

## How other blueprint repos handle testing

Common patterns observed in public Home Assistant blueprint repos:

1. **YAML lint** (cheap, catches indentation / syntax mistakes early)
   - [`yamllint`](https://yamllint.readthedocs.io/) configured via a top-level `.yamllint`
   - Often wired to PRs through [`reviewdog/action-yamllint`](https://github.com/reviewdog/action-yamllint)
   - Example: `EPMatt/awesome-ha-blueprints` runs yamllint on every PR (`.github/workflows/ci_pr.yml`)
2. **Formatter check** — `prettier --check .` so all YAML stays consistently formatted
3. **HA schema validation** (the strongest check — catches invalid selectors, bad action references, version mismatches, etc.):
   - Spin up a real HA in Docker or a venv, drop the blueprint into `blueprints/automation/<author>/`, and run `python -m homeassistant --script check_config -c /config`
   - This is exactly what the Docker step above does
4. **Manual import test** — most blueprint authors still import into their personal HA instance once before publishing, because some issues (e.g. selector UX, device-trigger filters matching the real device) only surface there
5. **(Larger projects only)** Custom build tooling — e.g. `awesome-ha-blueprints` has a TypeScript pipeline that auto-generates docs from blueprint frontmatter and verifies cross-blueprint consistency

A reasonable minimum for a small repo like this one is `yamllint` + the `check_config` Docker step, optionally wired into a GitHub Actions workflow.
