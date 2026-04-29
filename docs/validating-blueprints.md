# Validating Home Assistant blueprints

This repo uses a layered validation approach so problems are caught locally before they hit a real Home Assistant instance.

## TL;DR — one command

```bash
bash scripts/validate-blueprints.sh                 # all blueprints, all layers
bash scripts/validate-blueprints.sh --pull          # force docker pull first
bash scripts/validate-blueprints.sh blueprints/automation/styrbar_dim_to_warm.yaml
```

Both layers run inside the official `ghcr.io/home-assistant/home-assistant:stable` image, so the only host requirements are `bash` and `docker` — no host Python, no venv. The image is pulled lazily by docker on first use; pass `--pull` to force a refresh.

The same script powers:

- **VS Code tasks** — *Terminal → Run Task → “Validate blueprints”* (or *Validate current blueprint*). See [.vscode/tasks.json](../.vscode/tasks.json).
- **GitHub Actions** — see [.github/workflows/validate.yml](../.github/workflows/validate.yml). Runs on every push/PR that touches `blueprints/**`.

On Windows, run the script from **WSL** (`bash`) or Git Bash; Docker Desktop's WSL integration provides the `docker` CLI inside both.

## Layer 1 — YAML + `!input` parse (fast)

Catches indentation, quoting, and tag errors. Home Assistant's `!input` / `!secret` / `!include` tags must be registered with the loader. The script streams a small Python script into `python` inside the HA image, which already ships with PyYAML. Manual equivalent:

```bash
docker run --rm -i \
  --mount "type=bind,source=$(pwd),target=/repo,readonly" \
  --workdir /repo \
  --entrypoint python ghcr.io/home-assistant/home-assistant:stable \
  - blueprints/automation/*.yaml <<'PY'
import sys, yaml
class HALoader(yaml.SafeLoader): pass
def _tag(loader, node):
    return {"!input": loader.construct_scalar(node)}
HALoader.add_constructor("!input", _tag)
HALoader.add_constructor("!secret", _tag)
HALoader.add_constructor("!include", _tag)
for p in sys.argv[1:]:
    yaml.load(open(p, encoding="utf-8"), Loader=HALoader)
    print("OK", p)
PY
```

## Layer 2 — `yamllint` (style)

Enforced in CI via the [.yamllint](../.yamllint) config (relaxes `line-length`, `document-start`, `truthy` for HA blueprints; ignores `.ha-validate/` and `references/`). Run locally without installing anything via Docker:

```bash
docker run --rm \
  --mount "type=bind,source=$(pwd),target=/repo,readonly" \
  --workdir /repo \
  cytopia/yamllint:latest -c .yamllint blueprints/
```

This is *not* part of `validate-blueprints.sh` (the script focuses on HA-specific layers); it runs in the `yamllint` CI job and is the easiest way to lint locally.

## Layer 3 — Real Home Assistant `check_config` (definitive)

Spins up an actual HA against a tiny staged config dir and runs the blueprint through HA's own schema validators. Catches things YAML lint can't: invalid selectors, bad action references, unknown trigger types, version mismatches.

The repo includes [.ha-validate/](../.ha-validate/) as a staging dir:

```
.ha-validate/
├── configuration.yaml                     # just `default_config:`
└── blueprints/automation/local/
    └── .gitkeep                            # mount target; bind-mounted at runtime
```

The script bind-mounts the actual `blueprints/automation/` source tree into the container at `/config/blueprints/automation/local` (read-only), so blueprints are never copied or duplicated.

Manual equivalent:

```bash
docker run --rm \
  --mount "type=bind,source=$(pwd)/.ha-validate,target=/config" \
  --mount "type=bind,source=$(pwd)/blueprints/automation,target=/config/blueprints/automation/local,readonly" \
  --entrypoint python ghcr.io/home-assistant/home-assistant:stable \
  -m homeassistant --script check_config -c /config
```

Successful run prints `Testing configuration at /config` and exits with code `0`. Failures print red error blocks naming the offending field.

### Common errors and fixes

| Error contains | Likely cause |
|---|---|
| `expected a dictionary for dictionary value @ data['target']` | Used `target: !input lights` where `lights` is an `entity` selector. Wrap as `target:\n  entity_id: !input lights`. |
| `extra keys not allowed @ data['<key>']` | Typo in a key name, or used a key that's not part of the automation/blueprint schema at that nesting level. |
| `not a valid value for dictionary value @ data['blueprint']['input'][...]['selector']` | Selector type is wrong or its options don't match the schema (e.g. `step` outside the allowed range). |
| `Invalid blueprint: ...` during HA startup but `check_config` passes | Often a runtime template error (wrong filter, accessing `none` attributes). Test in a real HA. |

## Layer 4 — Manual import test (always do this once)

Some classes of bug only surface in a live HA:

- The device-trigger `selector: device` filter not matching your real Zigbee2MQTT model strings (z2m 1.x vs 2.x format differences are real).
- Selector UX issues (slider feels wrong, default not sensible).
- Edge cases in `state` triggers from the actual lights you use.

Steps:

1. Copy the blueprint to `<ha-config>/blueprints/automation/local/`.
2. Reload automations or restart HA.
3. *Settings → Automations & Scenes → Blueprints* → create an automation from it.
4. Trigger the remote / change a light / etc. and watch *Developer Tools → Logs*.

## What CI runs (PR test suite)

[.github/workflows/validate.yml](../.github/workflows/validate.yml) runs on every push to `main` and every PR. Jobs:

| Job | What it does | Required? |
|---|---|---|
| `yaml-syntax` | `validate-blueprints.sh --layer 1` | yes |
| `ha-check-config` | `validate-blueprints.sh --layer 2` against `:stable` | yes |
| `ha-check-config-beta` | same against `:beta` | advisory (`continue-on-error: true`) |
| `yamllint` | `cytopia/yamllint` against `.yamllint` | yes |
| `test-suite` | aggregate gate that fails if any required job failed | yes — make this the required check in branch protection |

The script flags it relies on:

- `--layer 1\|2\|all` — run only one layer (default `all`).
- `--image <ref>` — override the HA image (default `ghcr.io/home-assistant/home-assistant:stable`).
- `--pull` — force `docker pull` before running.

To enforce the suite on PRs, in GitHub: *Settings → Branches → Branch protection rule for `main` → Require status checks → add `test-suite`.*

## How other public repos test

Patterns observed in widely-used blueprint repos (e.g. `EPMatt/awesome-ha-blueprints`):

1. **`yamllint` on every PR** via [`reviewdog/action-yamllint`](https://github.com/reviewdog/action-yamllint).
2. **`prettier --check .`** for consistent formatting.
3. **Manual import** into the maintainer's HA instance before release.
4. (Larger projects only) Custom build tooling that auto-generates docs from blueprint frontmatter and verifies cross-blueprint references.

Most repos do **not** run HA's `check_config` in CI (it's heavier than a yaml lint), but it's the single highest-signal local check and is wired in here.
