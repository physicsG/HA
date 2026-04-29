---
description: "Use when authoring, modifying, reviewing, or debugging Home Assistant blueprint YAML files (automation, script, template). Covers blueprint schema, selectors, !input/template interaction, common HA-specific pitfalls, and the local validation workflow."
applyTo: "blueprints/**/*.yaml"
---

# Home Assistant blueprint authoring

These rules apply to every YAML file under `blueprints/`. **Files under `blueprints/*/references/` are read-only upstream copies — do not modify them.**

## Required structure

Every blueprint must have:

```yaml
blueprint:
  name: <short, user-facing>
  description: |
    <markdown description shown in the HA UI; keep first line short>
  source_url: <stable URL>
  domain: automation        # or script / template
  homeassistant:
    min_version: 2024.10.0  # bump only when using a feature that requires it
  input:
    <input_key>:
      name: <user-facing>
      description: <user-facing>
      default: <optional; omit to mark required>
      selector:
        <selector type>: { ... }

# automation domain only:
mode: single | restart | queued | parallel
max: <int>                  # required for queued/parallel
max_exceeded: silent | warning | error
variables: { ... }          # optional; converts !input values for use in templates
triggers: [...]
conditions: [...]           # optional
actions: [...]
```

## `!input` rules (the #1 source of bugs)

`!input <key>` is a YAML constructor, not a template. It is replaced **before** template rendering.

- **Use as a value**, not inside a string: `device_id: !input controller_device` ✅, `'{{ !input controller_device }}'` ❌.
- **To use an input in a template**, first promote it to a variable in `variables:`, then reference the variable with `{{ name }}`.
- **`target:` form depends on the selector**:
  - `selector: target` → input value is a `{entity_id, device_id, area_id}` dict → use `target: !input lights`
  - `selector: entity` (multiple or single) → input value is a string or list of entity IDs → use `target:\n  entity_id: !input lights`
  - Mixing these is the most common schema error. Always match.

## Selector cheatsheet

| Selector | Returns | Notes |
|---|---|---|
| `entity` | `entity_id` string (or list with `multiple: true`) | Filter with `domain:`, `device_class:`, `integration:` |
| `target` | dict of `entity_id` / `device_id` / `area_id` | Use as `target: !input x` directly |
| `device` | device ID string | Use `filter:` (list of integration/manufacturer/model dicts) for device-trigger selectors |
| `number` | numeric | Always provide `min`, `max`, `step`, `mode: slider \| box`, `unit_of_measurement` for sliders |
| `boolean` | `true`/`false` | |
| `action` | list of actions | Default `[]`; embed via `sequence: !input <key>` inside a `choose` with empty `conditions: []` |
| `select` | string | Provide `options:` list |

## Common pitfalls

- **Templates using `lights | length`** when `lights` came from a `target` selector → it's a dict, not a list. Either switch to `entity` selector with `multiple: true`, or expand via `expand(lights.entity_id)`.
- **`event.data` vs `payload`** depends on integration. For Zigbee2MQTT MQTT device triggers the action string is on `trigger.payload`. For deCONZ/ZHA it's nested in `trigger.event.data`.
- **`color_temp_kelvin`** is the modern key; avoid the deprecated `color_temp` (mireds).
- **`mode: restart`** cancels in-flight runs on a new trigger — great for remote-button loops, bad when a `state` trigger from N lights would cancel a remote press. Use `mode: parallel` with explicit echo suppression instead.
- **`input_text` helpers** are limited to 100 chars by default; keep stored JSON small (single-letter keys: `{"a":...,"t":...}`).
- **Defaults**: numeric inputs whose `default:` falls outside `min..max` will silently fail to load. Double-check ranges.

## License & attribution

When adapting code from an upstream blueprint:

1. Keep a header comment naming the source project, URL, and license (MIT for the upstreams in `references/`).
2. Only copy logic — never copy verbatim large blocks of `description:` / branding text from another project.

## Validation checklist (run after every meaningful edit)

The single-source-of-truth command is:

```bash
bash scripts/validate-blueprints.sh                       # all blueprints, both layers
bash scripts/validate-blueprints.sh --pull                # force docker pull first
bash scripts/validate-blueprints.sh path/to/blueprint.yaml
```

The script runs:

1. **YAML + `!input` parse** \u2014 PyYAML inside the HA Docker image.
2. **HA `check_config`** via the `ghcr.io/home-assistant/home-assistant:stable` image, after staging the changed blueprints into `.ha-validate/blueprints/automation/local/`.

Both layers run inside the same Docker image, so only `bash` and `docker` are required on the host. It must exit `0`. The same script runs in CI via [.github/workflows/validate.yml](../workflows/validate.yml) and is exposed as the VS Code task *“Validate blueprints”* (default test task). On Windows, run it from WSL or Git Bash.

For non-trivial logic changes, also ask the user to import into their real HA instance — selector UX, real device-trigger filter matches, and runtime template behavior need a live HA.

If validation fails, see the error table in [docs/validating-blueprints.md](../../docs/validating-blueprints.md#common-errors-and-fixes).
