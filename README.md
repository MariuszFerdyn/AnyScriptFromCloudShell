# AnyScriptFromCloudShell

## Project Overview

This project downloads and runs scripts (Bash, Azure CLI, Python, or any other
interpreter available in a container image) from network sources and executes
them inside isolated, disposable containers. It is designed around the idea
of an "Azure Cloud Shell in a box": any container image that ships the tools
you need (e.g. `mcr.microsoft.com/azure-cli`) can pull a script from the
network and run it on demand. It can be run locally with Docker or deployed
to Azure services such as Azure Container Apps (Container App Jobs), Azure
App Service, and more.

## Description

This project creates a workflow that:

1. Downloads a script from a network location such as a URL or Azure Storage blob
2. Executes the script inside an isolated container (Docker locally, or an Azure-hosted container)
3. Can authenticate to Azure using a system-assigned managed identity when running in Azure
4. Can be deployed across various Azure cloud services

## Key Features

- **Language-agnostic**: Works with Bash, Azure CLI, Python, or any script your container image can run
- **Isolation**: Runs scripts in containerized environments for security and dependency management
- **Cloud-ready**: Compatible with multiple Azure deployment options
- **Secure by default**: Supports Azure managed identity authentication instead of embedded credentials
- **Automation**: Can be scheduled or triggered as needed
- **Flexibility**: Works with any script accessible over a network

## Use Cases

- Running scheduled data processing or reporting jobs
- Executing maintenance and governance scripts across distributed systems
- Auditing/reporting on all subscriptions and resource groups an identity can access
- Deploying algorithm updates without rebuilding entire applications
- Creating serverless function-like capabilities with custom script logic

## Examples

### Azure Cloud Shell (Bash) Example

The [`AzureCloudShellBash`](./AzureCloudShellBash) folder contains
[`list_subscriptions_and_resourcegroups.sh`](./AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh),
a Bash script that lists every Azure subscription visible to the
authenticated identity and enumerates the resource groups inside each one.

#### Docker Command Example

```bash
docker run -it --rm --name my-cloudshell-script mcr.microsoft.com/azure-cli /bin/bash -c "az login --use-device-code && wget -O /opt/list_subscriptions_and_resourcegroups.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh && chmod +x /opt/list_subscriptions_and_resourcegroups.sh && cd /opt && ./list_subscriptions_and_resourcegroups.sh"
```

#### Azure Container App Example

```bash
# Login to Azure
az login 
        
# Set the subscription context
az account set --subscription $subscriptionId
        
# Create a new resource group for the gallery if it doesn't exist
az group create --name $ResourceGroup --location $location
        
# Prepare env
az extension add --name containerapp --upgrade --allow-preview true
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights

# Create Container App Enviorment
az containerapp env create --name $Enviorment --resource-group $ResourceGroup --location $location

# Create the Container App Job with a system-assigned managed identity.
# The job's command runs "az login --identity" first to authenticate as the
# managed identity, then downloads and runs the Bash script.
az containerapp job create --name list-subscriptions-job --resource-group $ResourceGroup --environment $Enviorment --trigger-type Manual --replica-timeout 1800 --replica-retry-limit 1 --replica-completion-count 1 --image mcr.microsoft.com/azure-cli --mi-system-assigned --command-line "/bin/bash -c 'az login --identity && wget -O /opt/list_subscriptions_and_resourcegroups.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh && chmod +x /opt/list_subscriptions_and_resourcegroups.sh && cd /opt && ./list_subscriptions_and_resourcegroups.sh'" --cpu 0.5 --memory 1.0Gi

# Get the principal ID of the Container App Job's system-assigned managed identity
principalId=$(az containerapp job show --name list-subscriptions-job --resource-group $ResourceGroup --query identity.principalId --output tsv)

# Grant the managed identity Reader (read-only) access to every subscription
# the currently logged-in user can see, so the script can enumerate them all.
for subId in $(az account list --all --query "[].id" --output tsv); do
    az role assignment create --assignee "$principalId" --role "Reader" --scope "/subscriptions/$subId"
done

# Start the job
az containerapp job start --name list-subscriptions-job --resource-group $ResourceGroup
```     
---

### Storing the Script in Azure Storage Account

The script can be stored in an Azure Storage Account as a blob. To provide secure access, you can generate a Shared Access Signature (SAS) token with the following features:
- **Read-Only Access**: Grant access with permissions limited to reading the blob.
- **Time-Based Access**: Specify a time window during which the token is valid, ensuring temporary access.
- **IP Address Restrictions**: Restrict access to specific IP addresses for added security.

For more information on generating SAS tokens, refer to the [Azure Documentation on Shared Access Signatures](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview).
