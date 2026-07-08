# AnyScriptFromCloudShell

## Project Overview

This project downloads and runs scripts (Bash, Azure CLI, Python, or any other
interpreter available in a container image) from network sources and executes
them inside isolated, disposable containers. It is designed around the idea
of an "Azure Cloud Shell in a box": any container image that ships the tools
you need (e.g. `mcr.microsoft.com/azure-cloudshell:latest`) can pull a script from the
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
docker run -it --rm --name my-cloudshell-script mcr.microsoft.com/azure-cloudshell:latest /bin/bash -c "az login --use-device-code && wget -O /opt/list_subscriptions_and_resourcegroups.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh && chmod +x /opt/list_subscriptions_and_resourcegroups.sh && cd /opt && ./list_subscriptions_and_resourcegroups.sh"
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

# Get the resource ID of the Container App Environment (needed by the YAML manifest below)
environmentId=$(az containerapp env show --name $Enviorment --resource-group $ResourceGroup --query id --output tsv)

# Create the Container App Job using a YAML manifest instead of "--command"/"--args"
# CLI flags. This avoids a well-known Azure CLI argparse limitation: passing a
# dash-prefixed value such as "-c" through "--args" makes the CLI misinterpret
# it as one of its own (unrecognized) options. Defining command/args in YAML
# sidesteps that limitation entirely.
# The container's command runs "az login --identity" first to authenticate as
# the job's system-assigned managed identity, then downloads and runs the
# Bash script.
cat <<EOF > list-subscriptions-job.yaml
location: $location
identity:
  type: SystemAssigned
properties:
  environmentId: $environmentId
  configuration:
    triggerType: Manual
    replicaTimeout: 1800
    replicaRetryLimit: 1
    manualTriggerConfig:
      replicaCompletionCount: 1
      parallelism: 1
  template:
    containers:
      - image: mcr.microsoft.com/azure-cloudshell:latest
        name: list-subscriptions-job
        command:
          - /bin/bash
        args:
          - -c
          - "wget -O /opt/az-patch.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/patch/az-patch.sh && bash /opt/az-patch.sh && az login --identity && wget -O /opt/list_subscriptions_and_resourcegroups.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh && chmod +x /opt/list_subscriptions_and_resourcegroups.sh && cd /opt && ./list_subscriptions_and_resourcegroups.sh"
        resources:
          cpu: 0.5
          memory: 1.0Gi
EOF

az containerapp job create --name list-subscriptions-job --resource-group $ResourceGroup --yaml list-subscriptions-job.yaml

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

#### Known Bug: Managed Identity in Azure Container Apps

The `mcr.microsoft.com/azure-cloudshell:latest` image ships a version of the
Azure CLI whose managed-identity (MSI) authentication code issues an old,
IMDS-style `POST` request. That request format is not compatible with the
managed-identity token endpoint used by Azure Container Apps (which expects a
`GET` request against `IDENTITY_ENDPOINT`/`MSI_ENDPOINT` using the
`IDENTITY_HEADER`/`MSI_SECRET` secret). As a result, `az login --identity`
fails when this image is run as a Container App Job/App with a managed
identity assigned.

[`patch/az-patch.sh`](./patch/az-patch.sh) works around this by locating the
affected Azure CLI file inside the container and patching the request in
place to use the correct `GET`-based call and headers. Run it as the very
first step of the container's command, **before** `az login --identity`.

#### Simpler Alternative: PowerShell

> **Note:** Run the following from PowerShell (not Bash/cmd), since it uses
> the `` ` `` line-continuation character and PowerShell here-strings.

For simple cases where the container's arguments don't start with a dash
(`-`), you can skip the YAML manifest entirely and pass `--command`/`--args`
straight on the command line — the same way you'd create a plain Container
App, just targeting a Container App Job instead:

```powershell
az containerapp job create `
  --name debug-shell `
  --resource-group administrative-tasks `
  --environment administrative-tasks `
  --trigger-type Manual `
  --replica-timeout 1800 `
  --image mcr.microsoft.com/azure-cloudshell:latest `
  --command "sleep" `
  --args "infinity" `
  --cpu 0.5 --memory 1Gi
```

However, this repo's real use case needs the container to run
`/bin/bash -c "<script>"`, and `-c` is a **dash-prefixed** value. That's a
known Azure CLI/argparse limitation (verified against `az` 2.71.0): whenever
`-c` appears as one of the `--args` tokens — as its own token, glued with
`--args=`, before or after other values — the CLI rejects it with
`unrecognized arguments: -c`. This is a limitation of the Azure CLI's own
argument parser, **not** a Bash-only quirk, so it happens identically in
PowerShell. The only reliable workaround is still a YAML manifest — but from
PowerShell you can build that YAML far more simply than with Bash's
`cat <<EOF`, using a native PowerShell here-string (`@".."@`) instead:

```powershell
# Login to Azure
az login

# Set the subscription context
az account set --subscription $subscriptionId

# Create a new resource group if it doesn't exist
az group create --name $ResourceGroup --location $location

# Prepare env
az extension add --name containerapp --upgrade --allow-preview true
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights

# Create Container App Environment
az containerapp env create --name $Environment --resource-group $ResourceGroup --location $location

# Get the resource ID of the Container App Environment (needed by the YAML manifest below)
$environmentId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id --output tsv

# Build the YAML manifest with a PowerShell here-string (no need for Bash's
# "cat <<EOF" syntax). The container's command first downloads and applies
# patch/az-patch.sh to fix the managed-identity bug described above, then
# runs "az login --identity", then downloads and runs the Bash script.
$yaml = @"
location: $location
identity:
  type: SystemAssigned
properties:
  environmentId: $environmentId
  configuration:
    triggerType: Manual
    replicaTimeout: 1800
    replicaRetryLimit: 1
    manualTriggerConfig:
      replicaCompletionCount: 1
      parallelism: 1
  template:
    containers:
      - image: mcr.microsoft.com/azure-cloudshell:latest
        name: list-subscriptions-job
        command:
          - /bin/bash
        args:
          - -c
          - "wget -O /opt/az-patch.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/patch/az-patch.sh && bash /opt/az-patch.sh && az login --identity && wget -O /opt/list_subscriptions_and_resourcegroups.sh https://raw.githubusercontent.com/MariuszFerdyn/AnyScriptFromCloudShell/main/AzureCloudShellBash/list_subscriptions_and_resourcegroups.sh && chmod +x /opt/list_subscriptions_and_resourcegroups.sh && cd /opt && ./list_subscriptions_and_resourcegroups.sh"
        resources:
          cpu: 0.5
          memory: 1.0Gi
"@
Set-Content -Path list-subscriptions-job.yaml -Value $yaml

az containerapp job create --name list-subscriptions-job --resource-group $ResourceGroup --yaml list-subscriptions-job.yaml

# Get the principal ID of the Container App Job's system-assigned managed identity
$principalId = az containerapp job show --name list-subscriptions-job --resource-group $ResourceGroup --query identity.principalId --output tsv

# Grant the managed identity Reader (read-only) access to every subscription
# the currently logged-in user can see, so the script can enumerate them all.
foreach ($subId in (az account list --all --query "[].id" --output tsv)) {
    az role assignment create --assignee $principalId --role "Reader" --scope "/subscriptions/$subId"
}

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

---

### Worth Knowing: Running Azure Cloud Shell Locally

The `mcr.microsoft.com/azure-cloudshell:latest` image isn't just useful for
running scripts unattended — it's also a nice way to get a full local Azure
Cloud Shell experience (Azure CLI, `kubectl`, `jq`, and other tools
pre-installed) in a disposable container on your own machine, without needing
a browser or the hosted Azure Cloud Shell:

```bash
docker run -it --rm --name my-cloudshell-script mcr.microsoft.com/azure-cloudshell:latest /bin/bash
```
