#!/bin/bash
#
# list_subscriptions_and_resourcegroups.sh
#
# Lists all Azure subscriptions visible to the current identity, then
# enumerates and displays all resource groups inside each subscription.
#
# Intended to run inside an Azure Cloud Shell compatible container image
# (mcr.microsoft.com/azure-cli), which already has the Azure CLI installed.
#
# Authentication is expected to already be established before this script
# runs (e.g. "az login --identity" when using a system-assigned managed
# identity). See README.md for a full example.

set -euo pipefail

echo "======================================================================"
echo "Azure Subscription and Resource Group Enumeration"
echo "======================================================================"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo

# Get the list of subscriptions visible to the currently authenticated identity
subscriptions=$(az account list --all --output json)

subscription_count=$(echo "$subscriptions" | jq 'length')
echo "Found ${subscription_count} subscription(s)"
echo "======================================================================"
echo

# Iterate over each subscription
echo "$subscriptions" | jq -c '.[]' | while read -r sub; do
    subscription_id=$(echo "$sub" | jq -r '.id')
    subscription_name=$(echo "$sub" | jq -r '.name')

    echo "----------------------------------------------------------------------"
    echo "Subscription: ${subscription_name}"
    echo "Subscription ID: ${subscription_id}"
    echo "----------------------------------------------------------------------"

    # Switch context to the subscription so subsequent az commands target it
    az account set --subscription "${subscription_id}"

    # Enumerate resource groups in this subscription
    resource_groups=$(az group list --output json)
    rg_count=$(echo "$resource_groups" | jq 'length')

    echo "Resource groups found: ${rg_count}"

    if [ "$rg_count" -eq 0 ]; then
        echo "  (no resource groups in this subscription)"
    else
        echo "$resource_groups" | jq -r '.[] | "  - \(.name) (location: \(.location), state: \(.properties.provisioningState))"'
    fi

    echo
done

echo "======================================================================"
echo "End time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Done."
echo "======================================================================"
