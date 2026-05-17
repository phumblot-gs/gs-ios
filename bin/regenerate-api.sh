#!/usr/bin/env bash
# Regenerate the GSAPIClient Swift client from the backend OpenAPI spec.
#
# Pipeline (TODO: implement):
#   1. Download swagger.json from the production backend.
#      e.g. curl -fsSL https://api.mobile.grand-shooting.com/swagger.json -o /tmp/swagger.json
#   2. Convert Swagger 2.0 → OpenAPI 3.x with swagger2openapi.
#      e.g. npx -y swagger2openapi /tmp/swagger.json -o Packages/GSAPIClient/openapi/openapi.yaml --yaml
#   3. Run swift-openapi-generator (declared as an SPM build plugin in
#      Packages/GSAPIClient/Package.swift) by simply building the target —
#      generation happens at build time.
#      e.g. swift build --package-path Packages/GSAPIClient
#
# For now this is a no-op so CI doesn't fail.

set -euo pipefail

echo "TODO: implement OpenAPI regeneration pipeline."
exit 0
