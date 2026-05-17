#!/usr/bin/env bash
# Regenerate the GSAPIClient Swift client from the Grand Shooting OpenAPI spec.
#
# Pipeline:
#   1. Download swagger.json (Swagger 2.0) from api.grand-shooting.com
#   2. Convert to OpenAPI 3.0 via swagger2openapi (npx, no install needed)
#   3. Post-process to fix three real-world issues with the converted spec:
#      a) Strip non-standard `{ value: { allowUnknown: true } }` enum entries
#      b) Lowercase duplicated tag spellings that clash under any naming strategy
#      c) Lift missing path-level parameters so every operation under
#         /resource/{id} sees the {id} parameter
#   4. The OpenAPIGenerator SPM build plugin in Packages/GSAPIClient/Package.swift
#      regenerates the Swift client on the next `swift build`
#
# Run from repo root: ./bin/regenerate-api.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${REPO_ROOT}/Packages/GSAPIClient/Sources/GSAPIClient"
SWAGGER_URL="${SWAGGER_URL:-https://api.grand-shooting.com/swagger.json}"

echo "→ Downloading ${SWAGGER_URL}"
curl -fsSL "${SWAGGER_URL}" -o "${TARGET_DIR}/swagger.json"

echo "→ Converting Swagger 2.0 → OpenAPI 3.0"
npx --yes swagger2openapi@latest \
    "${TARGET_DIR}/swagger.json" \
    --outfile "${TARGET_DIR}/openapi.yaml" \
    --yaml

echo "→ Post-processing spec"
VENV="${TMPDIR:-/tmp}/gs-spec-venv"
if [ ! -d "${VENV}" ]; then
    python3 -m venv "${VENV}"
    "${VENV}/bin/pip" install -q pyyaml
fi

"${VENV}/bin/python" - "${TARGET_DIR}/openapi.yaml" <<'PY'
import re
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
content = path.read_text()

# (a) Strip non-standard `{ value: { allowUnknown: true } }` enum entries.
content = re.sub(r' {6,8}- value:\n {10,12}allowUnknown: true\n', '', content)

# (b) Lowercase the few capitalized tag spellings (Style/Picture/Reference)
#     that conflict with their lowercase counterparts in the same spec.
for tag in ('Style', 'Picture', 'Reference'):
    content = re.sub(
        r'^(\s+-\s+)' + tag + r'\s*$',
        r'\g<1>' + tag.lower(),
        content,
        flags=re.MULTILINE
    )

spec = yaml.safe_load(content)

# (c) Lift missing path parameters to the path level.
OPERATION_KEYS = {'get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace'}
fixed_paths = 0
for path_url, path_item in spec.get('paths', {}).items():
    if not isinstance(path_item, dict):
        continue
    placeholders = re.findall(r'{([^}]+)}', path_url)
    if not placeholders:
        continue
    path_level_params = {
        p.get('name') for p in path_item.get('parameters', [])
        if isinstance(p, dict) and p.get('in') == 'path'
    }
    missing = []
    for ph in placeholders:
        if ph in path_level_params:
            continue
        ops_missing = False
        for op_key, op in path_item.items():
            if op_key not in OPERATION_KEYS or not isinstance(op, dict):
                continue
            op_params = {
                p.get('name') for p in op.get('parameters', [])
                if isinstance(p, dict) and p.get('in') == 'path'
            }
            if ph not in op_params:
                ops_missing = True
                break
        if ops_missing:
            missing.append(ph)
    if not missing:
        continue
    new_path_params = list(path_item.get('parameters', []))
    for ph in missing:
        template = None
        for op_key, op in path_item.items():
            if op_key not in OPERATION_KEYS or not isinstance(op, dict):
                continue
            for p in op.get('parameters', []):
                if isinstance(p, dict) and p.get('name') == ph and p.get('in') == 'path':
                    template = p
                    break
            if template:
                break
        if template is None:
            template = {
                'name': ph, 'in': 'path', 'required': True,
                'schema': {'type': 'string'}
            }
        new_path_params.append(template)
    path_item['parameters'] = new_path_params
    fixed_paths += 1

print(f'  lifted path params on {fixed_paths} paths')
path.write_text(yaml.safe_dump(spec, sort_keys=False, width=1000))
PY

echo "→ Updated:"
echo "    ${TARGET_DIR}/swagger.json (source)"
echo "    ${TARGET_DIR}/openapi.yaml (post-processed)"
echo ""
echo "Run \`swift build\` (or open Xcode) to regenerate the Swift client."
