#!/bin/bash

# If you don't have the Azure cli installed on your system go ahead and install it now
if [ -f "/usr/local/bin/az" ]; then
    echo "Azure cli already installed"
else
    echo "installing Azure cli..."
    brew update && brew install azure-cli
fi

az cloud set --name AzureCloud

echo "Log in with your Pivotal AD account on your browser"
az login

read -p 'Which support team are you a part of? (useast or uswest): ' GSS_TEAM
# You should only have one GSS subscription but just in case
SUBSCRIPTION_ID=$(az account list | grep -i $GSS_TEAM -B 3 | grep id | cut -b 12-47)
az account set --subscription $SUBSCRIPTION_ID

TENANT_ID=$(az account list | grep -i "GSS-CE-USEAST-AZURE" -A 2 | grep tenantId | cut -b 18-53)

read -p 'Please enter a new password for Service Principal for Bosh: ' SP_SECRET
read -p 'Please enter a unique identifier-uris value (Example: http://BoshAzureJSMITH) ' SP_NAME
read -p 'Please enter a unique name for your resource group - all lowercase (Example: jsmith): ' RESOURCE_GROUP

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

echo "Creating resource group..."
if [ $GSS_TEAM = "useast" ]; then
    LOCATION="eastus"
else
    LOCATION="westus"
fi

az group create -l $LOCATION -n $RESOURCE_GROUP

echo "Creating TAS network security group and access rules..."
az network nsg create --name tas-nsg \
--resource-group $RESOURCE_GROUP \
--location $LOCATION

az network nsg rule create --name ssh \
--nsg-name tas-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 100 \
--destination-port-range '22'

az network nsg rule create --name http \
--nsg-name tas-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 200 \
--destination-port-range '80'

az network nsg rule create --name https \
--nsg-name tas-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 300 \
--destination-port-range '443'

az network nsg rule create --name diego-ssh \
--nsg-name tas-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 400 \
--destination-port-range '2222'

echo "Creating Opsman network security group and access rules..."

az network nsg create --name opsmgr-nsg \
--resource-group $RESOURCE_GROUP \
--location $LOCATION

az network nsg rule create --name http \
--nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 100 \
--destination-port-range 80

az network nsg rule create --name https \
--nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 200 \
--destination-port-range 443

az network nsg rule create --name ssh \
--nsg-name opsmgr-nsg --resource-group $RESOURCE_GROUP \
--protocol Tcp --priority 300 \
--destination-port-range 22

echo "Creating TAS virtual network..."
az network vnet create --name tas-virtual-network \
--resource-group $RESOURCE_GROUP --location $LOCATION \
--address-prefixes 10.0.0.0/16

echo "Creating subnets..."
az network vnet subnet create --name tas-infrastructure-subnet \
--vnet-name tas-virtual-network \
--resource-group $RESOURCE_GROUP \
--address-prefix 10.0.4.0/26 \
--network-security-group tas-nsg
az network vnet subnet create --name tas-pas-subnet \
--vnet-name tas-virtual-network \
--resource-group $RESOURCE_GROUP \
--address-prefix 10.0.12.0/22 \
--network-security-group tas-nsg
az network vnet subnet create --name tas-services-subnet \
--vnet-name tas-virtual-network \
--resource-group $RESOURCE_GROUP \
--address-prefix 10.0.8.0/22 \
--network-security-group tas-nsg

echo "Creating Bosh storage account..."
STORAGE_NAME="${RESOURCE_GROUP}boshstorage4tas"
az storage account create --name $STORAGE_NAME \
--resource-group $RESOURCE_GROUP \
--sku Standard_LRS \
--location $LOCATION

CONNECTION_STRING=$(az storage account show-connection-string --name $STORAGE_NAME --resource-group $RESOURCE_GROUP | cut -c 24- | sed 's/"$//')

az storage container create --name opsmanager \
--connection-string $CONNECTION_STRING
az storage container create --name bosh \
--connection-string $CONNECTION_STRING
az storage container create --name stemcell --public-access blob \
--connection-string $CONNECTION_STRING

az storage table create --name stemcells \
--connection-string $CONNECTION_STRING

echo "Creating other storage accounts..."
STORAGE_TYPE="Premium_LRS"
STORAGE_NAME1="${RESOURCE_GROUP}boshstorage4tas1"
STORAGE_NAME2="${RESOURCE_GROUP}boshstorage4tas2"
STORAGE_NAME3="${RESOURCE_GROUP}boshstorage4tas3"

az storage account create --name $STORAGE_NAME1 \
--resource-group $RESOURCE_GROUP --sku $STORAGE_TYPE \
--kind Storage --location $LOCATION

CONNECTION_STRING1=$(az storage account show-connection-string --name $STORAGE_NAME1 --resource-group $RESOURCE_GROUP | cut -c 24- | sed 's/"$//')

az storage container create --name bosh \
--connection-string $CONNECTION_STRING1
az storage container create --name stemcell \
--connection-string $CONNECTION_STRING1

az storage account create --name $STORAGE_NAME2 \
--resource-group $RESOURCE_GROUP --sku $STORAGE_TYPE \
--kind Storage --location $LOCATION

CONNECTION_STRING2=$(az storage account show-connection-string --name $STORAGE_NAME2 --resource-group $RESOURCE_GROUP | cut -c 24- | sed 's/"$//')

az storage container create --name bosh \
--connection-string $CONNECTION_STRING2
az storage container create --name stemcell \
--connection-string $CONNECTION_STRING2

az storage account create --name $STORAGE_NAME3 \
--resource-group $RESOURCE_GROUP --sku $STORAGE_TYPE \
--kind Storage --location $LOCATION

CONNECTION_STRING3=$(az storage account show-connection-string --name $STORAGE_NAME3 --resource-group $RESOURCE_GROUP | cut -c 24- | sed 's/"$//')

az storage container create --name bosh \
--connection-string $CONNECTION_STRING3
az storage container create --name stemcell \
--connection-string $CONNECTION_STRING3