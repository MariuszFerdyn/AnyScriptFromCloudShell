#!/bin/bash
# az-patch.sh
#
# Workaround for a known bug in the mcr.microsoft.com/azure-cloudshell:latest
# image when it is used to authenticate with a managed identity inside
# Azure Container Apps (Container App Jobs).
#
# Azure Container Apps expose the managed identity token endpoint via the
# IDENTITY_ENDPOINT / IDENTITY_HEADER (or legacy MSI_ENDPOINT / MSI_SECRET)
# environment variables and expect a GET request with the secret passed as
# a header (Container Apps also accepts 'X-IDENTITY-HEADER'). The Azure CLI's
# bundled MSI authentication code instead issues a POST request with the
# legacy IMDS-style payload/headers, which fails inside Container Apps.
#
# This script locates the Python source file inside the image that contains
# the offending line and patches it in place so that `az login --identity`
# (and any subsequent `az` command) works correctly when the container is
# running as an Azure Container App Job / App with a managed identity.
#
# Usage: run this script as the very first step of the container command,
# before calling `az login --identity`, e.g.:
#   /bin/bash -c "bash /opt/patch/az-patch.sh && az login --identity && ..."
#
# The script is idempotent: running it more than once is safe.

set -euo pipefail

SEARCH_PATTERN="        result = requests.post(request_uri, data=payload, headers={'Metadata': 'true'})"

echo "[az-patch] Looking for the Azure CLI file(s) that need patching..."

# In the mcr.microsoft.com/azure-cloudshell:latest image the offending code
# lives in msrestazure's azure_active_directory.py, vendored under both the
# az CLI's own venv and (if present) the ansible venv, e.g.:
#   /usr/lib/az/lib/python3.12/site-packages/msrestazure/azure_active_directory.py
#   /opt/ansible/lib/python3.12/site-packages/msrestazure/azure_active_directory.py
# Search those known locations first (fast, sub-second), and only fall back
# to a full filesystem scan if nothing is found there, in case a future
# image version moves things around.
KNOWN_DIRS="/usr/lib/az /opt/az /opt/ansible /usr/lib/python3* /usr/local/lib/python3*"
MATCHES=$(grep -rl --include="*.py" -F "$SEARCH_PATTERN" $KNOWN_DIRS 2>/dev/null || true)

if [ -z "${MATCHES:-}" ]; then
  echo "[az-patch] Not found in known locations, falling back to a full filesystem search (this may take a while)..."
  MATCHES=$(grep -rl --include="*.py" -F "$SEARCH_PATTERN" / \
    --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev --exclude-dir=mnt 2>/dev/null || true)
fi

if [ -z "${MATCHES:-}" ]; then
  echo "[az-patch] Pattern not found. Either the image has already been patched, or this az CLI version does not contain the vulnerable code path. Skipping."
  exit 0
fi

while IFS= read -r MSR; do
  [ -z "$MSR" ] && continue
  echo "[az-patch] Patching file: $MSR"
  sed -i "s|        result = requests.post(request_uri, data=payload, headers={'Metadata': 'true'})|        _aca_secret = os.environ.get('MSI_SECRET') or os.environ.get('IDENTITY_HEADER')\n        _aca_headers = {'Metadata': 'true'}\n        if _aca_secret:\n            _aca_headers['secret'] = _aca_secret\n            _aca_headers['X-IDENTITY-HEADER'] = _aca_secret\n        if 'api-version' not in payload:\n            payload['api-version'] = os.environ.get('MSI_API_VERSION', '2017-09-01')\n        result = requests.get(request_uri, params=payload, headers=_aca_headers)|" "$MSR"
done <<< "$MATCHES"

echo "[az-patch] Patch applied successfully."
