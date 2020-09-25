#!/bin/bash

# If you don't have the Azure cli installed on your system go ahead and install it now
if [ -f "/usr/local/bin/az" ]; then
    echo "az cli already installed"
else
    echo "installing az cli..."
    brew update && brew install azure-cli
fi

az cloud set --name AzureCloud

echo "Log in with your Pivotal AD account on your browser"
az login

# You should only have one GSS subscription but just in case
SUBSCRIPTION_ID=$(az account list | grep -i "GSS-CE-USEAST-AZURE" -B 3 | grep id | cut -b 12-47)
az account set --subscription $SUBSCRIPTION_ID

TENANT_ID=$(az account list | grep -i "GSS-CE-USEAST-AZURE" -A 2 | grep tenantId | cut -b 18-53)

read -p 'Please enter a new password for Service Principal for Bosh: ' SP_SECRET
read -p 'Please enter a unique identifier-uris value (Example: http://BoshAzureJL) ' SP_NAME

az ad app create --display-name "Service Principal for BOSH" \
--password $SP_SECRET --homepage "http://BOSHAzureCPI" \
--identifier-uris $SP_NAME


APPLICATION_ID=$(az ad app list --identifier-uri $SP_NAME | grep appId | cut -b 15-50)

echo "Creating a Service Principal..."
az ad sp create --id $APPLICATION_ID

echo "Assigning your Service Principal the Owner role..."
sleep 5
az role assignment create --assignee $SP_NAME \
--role "Owner" --scope /subscriptions/$SUBSCRIPTION_ID

az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Compute
