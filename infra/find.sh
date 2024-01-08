#!/bin/bash

# Authenticate with Azure CLI before running commands
az account set --subscription AzureDev10

# Retrieve the publishing profile XML
publishXml=$(az webapp deployment list-publishing-profiles \
  --name $(az webapp list -g rg-webvideo --query "[].{name: name}" -o tsv) \
  --resource-group rg-webvideo \
  --query "[?publishMethod=='MSDeploy'].[publishUrl,userName,userPWD]" \
  --output tsv)

# Parse the XML for FTP username and password
userName=$(echo $publishXml | awk '{print $2}')
userPWD=$(echo $publishXml | awk '{print $3}')

# Return as JSON
echo "{\"username\": \"$userName\", \"password\": \"$userPWD\"}"
