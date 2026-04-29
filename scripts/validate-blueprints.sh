#!/usr/bin/env bash
# Validate every Home Assistant blueprint in this repo.
#
# Both layers run inside the official HA Docker image, so the only host
# requirements are `bash` and `docker`. No host Python, no venv.
#
# Layers:
#   1. YAML + !input parse check (PyYAML inside the HA image)
#   2. Home Assistant `check_config` (same image)
#
# Exits non-zero if any blueprint fails any layer. Designed to be invoked
# the same way from the command line, the VS Code task, and GitHub Actions.
#
# Usage:
#   scripts/validate-blueprints.sh                # all blueprints, both layers
#   scripts/validate-blueprints.sh --pull         # force docker pull first
#   scripts/validate-blueprints.sh --layer 1      # YAML+!input parse only
#   scripts/validate-blueprints.sh --layer 2      # HA check_config only
#   scripts/validate-blueprints.sh --image ghcr.io/home-assistant/home-assistant:beta
#   scripts/validate-blueprints.sh path/to/file.yaml

set -euo pipefail

HA_IMAGE="ghcr.io/home-assistant/home-assistant:stable"

PULL=0
LAYER="all"
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)  PULL=1; shift ;;
        --image) HA_IMAGE="$2"; shift 2 ;;
        --layer) LAYER="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *)
            TARGET="$1"; shift ;;
    esac
done

case "$LAYER" in
    1|2|all) ;;
    *) echo "--layer must be one of: 1, 2, all" >&2; exit 2 ;;
esac

# repo root = parent of this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# pretty printers (no colors when not a TTY)
if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi
step()  { printf "%s==> %s%s\n"  "$C_CYAN"   "$*" "$C_RESET"; }
ok()    { printf "    %sOK   %s%s\n" "$C_GREEN"  "$*" "$C_RESET"; }
fail()  { printf "    %sFAIL %s%s\n" "$C_RED"    "$*" "$C_RESET"; }
warn()  { printf "%s%s%s\n" "$C_YELLOW" "$*" "$C_RESET"; }

failures=()

# ---------------------------------------------------------------------------
# Pre-flight: docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found on PATH; install Docker Desktop (Windows/macOS) or docker-ce (Linux)"
    exit 1
fi

# Path-mangling guards. Git Bash / MSYS rewrites in-container paths like
# /config into C:/Program Files/Git/config; setting these env vars stops it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# Convert host paths for the docker CLI on Windows hosts (Git Bash / MSYS).
# In WSL and on Linux, the docker CLI is a Linux binary and accepts Linux
# paths natively, so no conversion is needed there.
host_path() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
        *)                    printf '%s' "$1" ;;
    esac
}

if [[ $PULL -eq 1 ]]; then
    step "Pulling $HA_IMAGE"
    docker pull --quiet "$HA_IMAGE"
fi

# ---------------------------------------------------------------------------
# Discover blueprint files
# ---------------------------------------------------------------------------
search_root="${TARGET:-blueprints}"
if [[ ! -e "$search_root" ]]; then
    warn "Path not found: $search_root"
    exit 1
fi

# collect *.yaml under search_root, excluding any /references/ folder
mapfile -t blueprints < <(
    find "$search_root" -type f -name '*.yaml' \
        -not -path '*/references/*' | sort
)

if [[ ${#blueprints[@]} -eq 0 ]]; then
    warn "No blueprint YAML files found under $search_root"
    exit 0
fi

step "Found ${#blueprints[@]} blueprint file(s) to validate"
for b in "${blueprints[@]}"; do printf "    - %s\n" "$b"; done

# ---------------------------------------------------------------------------
# Layer 1: YAML + !input parse (PyYAML inside the HA image)
# ---------------------------------------------------------------------------
if [[ "$LAYER" == "1" || "$LAYER" == "all" ]]; then
    step "Layer 1: YAML + !input parse check (in $HA_IMAGE)"

    repo_mount="$(host_path "$REPO_ROOT")"

    # Stream the parser script in via stdin so nothing has to be staged.
    parser_script=$(cat <<'PY'
import sys, yaml
class HALoader(yaml.SafeLoader): pass
def _tag(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return {"!input": loader.construct_scalar(node)}
    return None
HALoader.add_constructor("!input", _tag)
HALoader.add_constructor("!secret", _tag)
HALoader.add_constructor("!include", _tag)
ok = True
for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = yaml.load(f, Loader=HALoader)
        bp = (d or {}).get("blueprint")
        if not bp:
            print(f"FAIL {path}: no top-level 'blueprint:' key")
            ok = False
            continue
        n_inputs = len((bp.get("input") or {}))
        print(f"OK   {path}  ({n_inputs} inputs)")
    except yaml.YAMLError as e:
        print(f"FAIL {path}: {e}")
        ok = False
sys.exit(0 if ok else 1)
PY
)

    if ! docker run --rm -i \
            --mount "type=bind,source=${repo_mount},target=/repo,readonly" \
            --workdir /repo \
            --entrypoint python \
            "$HA_IMAGE" \
            - "${blueprints[@]}" <<<"$parser_script"; then
        failures+=("layer1: yaml parse")
    else
        ok "all blueprints parsed"
    fi
fi

# ---------------------------------------------------------------------------
# Layer 2: HA check_config (same image)
# ---------------------------------------------------------------------------
if [[ "$LAYER" == "2" || "$LAYER" == "all" ]]; then
    step "Layer 2: HA check_config (in $HA_IMAGE)"

    stage_dir="$REPO_ROOT/.ha-validate"
    stage_bp_dir="$stage_dir/blueprints/automation/local"
    stage_config="$stage_dir/configuration.yaml"

    # Make sure the staging dir + an empty mount-target dir exist so docker has
    # something to bind-mount onto. We never copy blueprints in here — the source
    # tree is bind-mounted directly via a second --mount below.
    mkdir -p "$stage_bp_dir"
    if [[ ! -f "$stage_config" ]]; then
        printf "default_config:\n" > "$stage_config"
    fi

    config_mount="$(host_path "$stage_dir")"
    bp_src_mount="$(host_path "$REPO_ROOT/blueprints/automation")"

    echo "    Running check_config ..."
    if ! docker run --rm \
            --mount "type=bind,source=${config_mount},target=/config" \
            --mount "type=bind,source=${bp_src_mount},target=/config/blueprints/automation/local,readonly" \
            --entrypoint python \
            "$HA_IMAGE" \
            -m homeassistant --script check_config -c /config; then
        fail "HA check_config failed"
        failures+=("layer2: check_config")
    else
        ok "HA check_config passed"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [[ ${#failures[@]} -eq 0 ]]; then
    printf "%sAll blueprint validation steps passed.%s\n" "$C_GREEN" "$C_RESET"
    exit 0
else
    printf "%sValidation failed:%s\n" "$C_RED" "$C_RESET"
    for f in "${failures[@]}"; do printf "  - %s\n" "$f"; done
    exit 1
fi
