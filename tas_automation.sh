#!/bin/bash
set -euo pipefail

# If you don't have the Azure cli installed on your system go ahead and install it now
if [ -f "/usr/local/bin/az" ]; then
    echo "Azure cli already installed"
else
    echo "installing Azure cli..."
    brew update
    brew install azure-cli
fi

# You can also install azcopy to move the blob
# if [ -f "/usr/local/bin/azcopy" ]; then
#     echo "Azcopy already installed"
# else
#     echo "installing azcopy..."
#     brew update && brew install azcopy
# fi

az cloud set --name AzureCloud

echo "Log in with your Pivotal AD account on your browser"
az login

read -p 'Please enter the Opsman exact version and build. 
You can find that info here https://network.pivotal.io/products/ops-manager/#/releases (Example: 2.9.11-build.186). : ' OPSMAN_VERSION
read -p 'Which support team are you a part of? (useast or uswest): ' GSS_TEAM
read -p 'Please enter a unique name for your resource group - all lowercase (Example: jsmith): ' RESOURCE_GROUP
read -sp 'Please enter a new password for Service Principal/Opsman: ' SP_SECRET
echo ''
read -sp 'Please enter your Mac admin password: ' MAC_ADMIN

# You should only have one GSS subscription but just in case
SUBSCRIPTION_ID=$(az account list | grep -i $GSS_TEAM -B 3 | grep id | cut -c 12-47)
TENANT_ID=$(az account list | grep -i $GSS_TEAM -A 2 | grep tenantId | cut -c 18-53)
SP_NAME="http://BoshAzure$RESOURCE_GROUP"

az account set --subscription $SUBSCRIPTION_ID
az ad app create --display-name "Service Principal for BOSH" \
--password $SP_SECRET --homepage "http://BOSHAzureCPI" \
--identifier-uris $SP_NAME

APPLICATION_ID=$(az ad app list --identifier-uri $SP_NAME | grep appId | cut -c 15-50)

echo "Creating a Service Principal..."
az ad sp create --id $APPLICATION_ID

sleep 60

echo "Assigning your Service Principal the Owner role..."
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
az network vnet subnet create --name tas-runtime-subnet \
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
STORAGE_NAME="${RESOURCE_GROUP}storage4tas"
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
STORAGE_NAME1="${RESOURCE_GROUP}storage4tas1"
STORAGE_NAME2="${RESOURCE_GROUP}storage4tas2"
STORAGE_NAME3="${RESOURCE_GROUP}storage4tas3"

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


echo "Creating Load Balancers..."

az network lb create --name pcf-lb \
--resource-group $RESOURCE_GROUP --location $LOCATION \
--backend-pool-name pcf-lb-be-pool --frontend-ip-name pcf-lb-fe-ip \
--public-ip-address pcf-lb-ip --public-ip-address-allocation Static \
--sku Standard

az network lb probe create --lb-name pcf-lb \
--name http8080 --resource-group $RESOURCE_GROUP \
--protocol Http --port 8080 --path health

az network lb rule create --lb-name pcf-lb \
--name http --resource-group $RESOURCE_GROUP \
--protocol Tcp --frontend-port 80 \
--backend-port 80 --frontend-ip-name pcf-lb-fe-ip \
--backend-pool-name pcf-lb-be-pool \
--probe-name http8080

az network lb rule create --lb-name pcf-lb \
--name https --resource-group $RESOURCE_GROUP \
--protocol Tcp --frontend-port 443 \
--backend-port 443 --frontend-ip-name pcf-lb-fe-ip \
--backend-pool-name pcf-lb-be-pool \
--probe-name http8080

# Boot Ops Manager
echo "copying image to storage..."
OPS_MAN_IMAGE_URL=https://opsmanager$LOCATION.blob.core.windows.net/images/ops-manager-$OPSMAN_VERSION.vhd

az storage blob copy start --source-uri $OPS_MAN_IMAGE_URL \
--connection-string $CONNECTION_STRING \
--destination-container opsmanager \
--destination-blob opsman-$OPSMAN_VERSION.vhd

#Alternatively, you can use azcopy to upload your image to storage
# EXPIRY=`date -v +1d +%Y-%m-%dT%H:%MZ`
# KEY=`az storage account keys list --account-name $STORAGE_NAME -o json | grep key1 -A 2 | grep value | cut -c 15-102`
# SAS=`az storage container generate-sas -n opsmanager --account-name $STORAGE_NAME --account-key $KEY --https-only --permissions dlrw --expiry $EXPIRY -o tsv`
# DESTINATION_STORAGE=https://$STORAGE_NAME.blob.core.windows.net/opsmanager/ops-manager-$OPSMAN_VERSION.vhd?$SAS
# azcopy copy "$OPS_MAN_IMAGE_URL" "$DESTINATION_STORAGE"

# Create a public IP for Ops Manager
az network public-ip create --name ops-manager-ip \
--resource-group $RESOURCE_GROUP --location $LOCATION \
--allocation-method Static

# Create a network interface for Ops Manager
az network nic create --vnet-name tas-virtual-network \
--subnet tas-infrastructure-subnet --network-security-group opsmgr-nsg \
--private-ip-address 10.0.4.4 \
--public-ip-address ops-manager-ip \
--resource-group $RESOURCE_GROUP \
--name opsman-nic --location $LOCATION

# Create a keypair
if [ -d "$HOME/.ssh/azurekeys" ]; then
    echo "Key pair already exists"
else
    echo "Creating a key pair in ~/.ssh/azurekeys"
    mkdir ~/.ssh/azurekeys
    ssh-keygen -t rsa -f ~/.ssh/azurekeys/opsman -C ubuntu -N ""
fi


get_status() {
  echo $(az storage blob show --name opsman-$OPSMAN_VERSION.vhd --connection-string $CONNECTION_STRING --container-name opsmanager | grep success | cut -c 18-24)
}

CPSTATUS="copying"

while [ "$CPSTATUS" != "success" ]; do
    CPSTATUS="$(get_status)"
    echo "blob is still copying..."
    sleep 30
done

echo "Transfer complete"

az image create --resource-group $RESOURCE_GROUP \
--name opsman-$OPSMAN_VERSION \
--source https://$STORAGE_NAME.blob.core.windows.net/opsmanager/opsman-$OPSMAN_VERSION.vhd \
--location $LOCATION \
--os-type Linux

az vm create --name opsman-$OPSMAN_VERSION --resource-group $RESOURCE_GROUP \
--location $LOCATION \
--nics opsman-nic \
--image opsman-$OPSMAN_VERSION \
--os-disk-size-gb 128 \
--os-disk-name opsman-$OPSMAN_VERSION-osdisk \
--admin-username ubuntu \
--size Standard_DS2_v2 \
--storage-sku Standard_LRS \
--ssh-key-value ~/.ssh/azurekeys/opsman.pub


OPSMAN_IP=$(az network public-ip show --name ops-manager-ip --resource-group $RESOURCE_GROUP | grep ipAddress | cut -c 17- | sed 's/",$//')
OPSMAN_URL="opsman.$RESOURCE_GROUP.taslab4tanzu.com"
echo $MAC_ADMIN | sudo -S sh -c -e "echo '$OPSMAN_IP' '$OPSMAN_URL' >> /etc/hosts"


opsman_authentication_setup()
{
  cat <<EOF
{
    "setup": {
    "decryption_passphrase": "$SP_SECRET",
    "decryption_passphrase_confirmation": "$SP_SECRET",
    "eula_accepted": "true",
    "identity_provider": "internal",
    "admin_user_name": "admin",
    "admin_password": "$SP_SECRET",
    "admin_password_confirmation": "$SP_SECRET"
    }
}
EOF
}

curl -k -X POST -H "Content-Type: application/json" -d "$(opsman_authentication_setup)" "https://$OPSMAN_URL/api/v0/setup"

echo "Setting up Opsman authentication..."
sleep 60

uaac target https://$OPSMAN_URL/uaa --skip-ssl-validation
uaac token owner get opsman admin -s "" -p $SP_SECRET
OPSMAN_TOKEN=$(uaac context | grep access_token | cut -c 21-)

director_newconfig()
{
  cat <<EOF
{
  "director_configuration": {
    "ntp_servers_string": "ntp.ubuntu.com",
    "resurrector_enabled": false,
    "director_hostname": null,
    "max_threads": null,
    "custom_ssh_banner": null,
    "metrics_server_enabled": true,
    "system_metrics_runtime_enabled": true,
    "opentsdb_ip": null,
    "director_worker_count": 5,
    "post_deploy_enabled": false,
    "bosh_recreate_on_next_deploy": false,
    "bosh_director_recreate_on_next_deploy": false,
    "bosh_recreate_persistent_disks_on_next_deploy": false,
    "retry_bosh_deploys": false,
    "keep_unreachable_vms": false,
    "identification_tags": {},
    "skip_director_drain": false,
    "job_configuration_on_tmpfs": false,
    "nats_max_payload_mb": null,
    "database_type": "internal",
    "blobstore_type": "local",
    "local_blobstore_options": {
      "enable_signed_urls": true
    },
    "hm_pager_duty_options": {
      "enabled": false
    },
    "hm_emailer_options": {
      "enabled": false
    },
    "encryption": {
      "keys": [],
      "providers": []
    }
  },
  "dns_configuration": {
    "excluded_recursors": [],
    "recursor_selection": null,
    "recursor_timeout": null,
    "handlers": []
  },
  "security_configuration": {
    "trusted_certificates": null,
    "generate_vm_passwords": true,
    "opsmanager_root_ca_trusted_certs": false
  },
  "syslog_configuration": {
    "enabled": false
  },
  "iaas_configuration": {
    "name": "default",
    "additional_cloud_properties": {},
    "subscription_id": "$SUBSCRIPTION_ID",
    "tenant_id": "$TENANT_ID",
    "client_id": "$SP_NAME",
    "client_secret": "$SP_SECRET",
    "resource_group_name": "$RESOURCE_GROUP",
    "bosh_storage_account_name": "$STORAGE_NAME",
    "cloud_storage_type": "managed_disks",
    "storage_account_type": "Premium_LRS",
    "default_security_group": null,
    "deployed_cloud_storage_type": null,
    "deployments_storage_account_name": null,
    "ssh_public_key": "$(cat ~/.ssh/azurekeys/opsman.pub)",
    "ssh_private_key": "$(cat ~/.ssh/azurekeys/opsman | tr -d '\n')",
    "environment": "AzureCloud",
    "availability_mode": "availability_zones"
  }
}
EOF
}

echo "Configuring bosh director..."
curl -k -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer $OPSMAN_TOKEN" -d "$(director_newconfig)" "https://$OPSMAN_URL/api/v0/staged/director/properties"

networks_config()
{
  cat <<EOF
{
    "icmp_checks_enabled": false,
    "networks": [
      {
        "guid": null,
        "name": "infrastructure",
        "subnets": [
          {
            "guid": null,
            "iaas_identifier": "tas-virtual-network/tas-infrastructure-subnet",
            "cidr": "10.0.4.0/26",
            "dns": "168.63.129.16",
            "gateway": "10.0.4.1",
            "reserved_ip_ranges": "10.0.4.1-10.0.4.9"
          }
        ]
      },
      {
        "guid": null,
        "name": "tas",
        "subnets": [
          {
            "guid": null,
            "iaas_identifier": "tas-virtual-network/tas-runtime-subnet",
            "cidr": "10.0.12.0/22",
            "dns": "168.63.129.16",
            "gateway": "10.0.12.1",
            "reserved_ip_ranges": "10.0.12.1-10.0.12.9"
          }
        ]
      }, 
      {
        "guid": null,
        "name": "services",
        "subnets": [
          {
            "guid": null,
            "iaas_identifier": "tas-virtual-network/tas-services-subnet",
            "cidr": "10.0.8.0/22",
            "dns": "168.63.129.16",
            "gateway": "10.0.8.1",
            "reserved_ip_ranges": "10.0.8.1-10.0.8.9"
          }
        ]
      } 
    ]
  }
EOF
}

curl -k -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer $OPSMAN_TOKEN" -d "$(networks_config)" "https://$OPSMAN_URL/api/v0/staged/director/networks"

az_singleton()
{
  cat <<EOF
{
  "network_and_az": {
    "network": {
      "name": "infrastructure"
    },
    "singleton_availability_zone": {
      "name": "zone-1"
    }
  }
}
EOF
}

curl -k -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer $OPSMAN_TOKEN" -d "$(az_singleton)" "https://$OPSMAN_URL/api/v0/staged/director/network_and_az"

apply_changes()
{
  cat <<EOF
{
"deploy_products": "all",
"ignore_warnings": true
}
EOF
}

echo "Starting apply changes..."
curl -k -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $OPSMAN_TOKEN" -d "$(apply_changes)" "https://$OPSMAN_URL/api/v0/installations"

echo "

Apply changes started, to check the status go to $OPSMAN_URL"
