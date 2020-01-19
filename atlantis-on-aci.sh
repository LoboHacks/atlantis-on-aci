#! /bin/bash

set -e

if [ "$GITHUB_USER" == "" ]; then
    echo "GITHUB_USER variable not set."
    exit 1
fi

if [ "$GITHUB_TOKEN" == "" ]; then
    echo "GITHUB_TOKEN variable not set."
    exit 1
fi

if [ "$GITHUB_WEBHOOK_SECRET" == "" ]; then
    GITHUB_WEBHOOK_SECRET=$(openssl rand -hex 32)
fi

if [ "$REPO_WHITELIST" == "" ]; then
    echo "REPO_WHITELIST variable not set."
    exit 1
fi

if [ "$ATLANTIS_LOCATION" == "" ]; then
    echo "ATLANTIS_LOCATION variable not set."
    exit 1
fi

if [ "$SUFFIX" == "" ]; then
    SUFFIX=$(cat /dev/urandom | LC_ALL=C LC_CTYPE=C tr -dc 'a-z0-9' | fold -w 10 | head -n 1)
fi

if [ "$ATLANTIS_RG_NAME" == "" ]; then
    ATLANTIS_RG_NAME="atlantis-resources-$SUFFIX"
fi

if [ "$ATLANTIS_STORAGE_NAME" == "" ]; then
    ATLANTIS_STORAGE_NAME=$(echo "atlantisstorage$SUFFIX" | head -c 24)
fi

if [ "$ATLANTIS_STORAGE_STATE_CONTAINER_NAME" == "" ]; then
    ATLANTIS_STORAGE_STATE_CONTAINER_NAME="atlantis-tf-state"
fi

if [ "$ATLANTIS_CONTAINER_GROUP_NAME" == "" ]; then
    ATLANTIS_CONTAINER_GROUP_NAME="atlantis-container-group-$SUFFIX"
fi

if [ "$ATLANTIS_CONTAINER_DNS_NAME" == "" ]; then
    ATLANTIS_CONTAINER_DNS_NAME="atlantis-server-$SUFFIX"
fi

if [ "$SKIP_CREDENTIALS_VALIDATION" == "" ]; then
    SKIP_CREDENTIALS_VALIDATION="true"
fi

if [ "$SKIP_PROVIDER_REGISTRATION" == "" ]; then
    SKIP_PROVIDER_REGISTRATION="true"
fi

az group create --location $ATLANTIS_LOCATION --name $ATLANTIS_RG_NAME --tags atlantis

az storage account create \
    --name $ATLANTIS_STORAGE_NAME \
    --resource-group $ATLANTIS_RG_NAME \
    --location $ATLANTIS_LOCATION \
    --sku Standard_LRS \
    --https-only true \
    --kind StorageV2 \
    --access-tier Hot

STORAGE_KEY=$(az storage account keys list \
    --account-name $ATLANTIS_STORAGE_NAME \
    --query "[0].value" | tr -d '"')

az storage container create \
    --name $ATLANTIS_STORAGE_STATE_CONTAINER_NAME \
    --account-name $ATLANTIS_STORAGE_NAME \
    --account-key $STORAGE_KEY

openssl req \
    -new \
    -newkey rsa:4096 \
    -x509 \
    -subj "/C=US/ST=Denial/L=Anytown/O=Dis/CN=$ATLANTIS_CONTAINER_DNS_NAME.$ATLANTIS_LOCATION.azurecontainer.io" \
    -sha256 \
    -days 365 \
    -nodes \
    -out atlantis.crt \
    -keyout atlantis.key

az storage share create \
    --name "atlantis-config-share" \
    --account-name $ATLANTIS_STORAGE_NAME \
    --account-key $STORAGE_KEY

az storage file upload \
    --share-name "atlantis-config-share" \
    --source ./atlantis.crt \
    --account-name $ATLANTIS_STORAGE_NAME \
    --account-key $STORAGE_KEY

az storage file upload \
    --share-name "atlantis-config-share" \
    --source ./repos.yaml \
    --account-name $ATLANTIS_STORAGE_NAME \
    --account-key $STORAGE_KEY

SUB_ID=$(az account show --query "id" | tr -d '"')

az container create \
    --name $ATLANTIS_CONTAINER_GROUP_NAME \
    --resource-group $ATLANTIS_RG_NAME \
    --location $ATLANTIS_LOCATION \
    --assign-identity \
    --scope /subscriptions/$SUB_ID \
    --azure-file-volume-account-name $ATLANTIS_STORAGE_NAME \
    --azure-file-volume-account-key $STORAGE_KEY \
    --azure-file-volume-share-name "atlantis-config-share" \
    --azure-file-volume-mount-path /mnt/atlantis-config \
    --image runatlantis/atlantis:latest \
    --os-type Linux \
    --restart-policy OnFailure \
    --cpu 1 \
    --memory 2 \
    --ports 4141 \
    --dns-name-label $ATLANTIS_CONTAINER_DNS_NAME \
    --command-line "atlantis server \
        --gh-user=$GITHUB_USER \
        --repo-whitelist=$REPO_WHITELIST \
        --repo-config=/mnt/atlantis-config/repos.yaml \
        --ssl-cert-file=/mnt/atlantis-config/atlantis.crt \
        --ssl-key-file=/mnt/secrets/atlantis_key" \
    --environment-variables \
        ARM_USE_MSI=true \
        ARM_SKIP_CREDENTIALS_VALIDATION=$SKIP_CREDENTIALS_VALIDATION \
        ARM_SKIP_PROVIDER_REGISTRATION=$SKIP_PROVIDER_REGISTRATION \
        ARM_SUBSCRIPTION_ID=$SUB_ID \
    --secure-environment-variables \
        ARM_ACCESS_KEY=$STORAGE_KEY \
        ATLANTIS_GH_TOKEN=$GITHUB_TOKEN \
        ATLANTIS_GH_WEBHOOK_SECRET=$GITHUB_WEBHOOK_SECRET \
    --secrets atlantis_key="$(cat atlantis.key)" \
    --secrets-mount-path /mnt/secrets

echo "Webhook URL: https://$ATLANTIS_CONTAINER_DNS_NAME.$ATLANTIS_LOCATION.azurecontainer.io:4141/events"
echo "Webhook secret: $GITHUB_WEBHOOK_SECRET"