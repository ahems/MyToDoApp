#!/usr/bin/env bash
set -euo pipefail

subscriptionId=$1
resourceGroup=$2
accountName=$3
modelName=${4:-gpt-5-mini}
location=${5:-canadaeast}

echo "Checking model availability for $modelName in $location"

# Ensure account exists (skip if you already created it)
if ! az cognitiveservices account show -n "$accountName" -g "$resourceGroup" &>/dev/null; then
  echo "Creating temp OpenAI account (S0) ..."
  az cognitiveservices account create \
    -n "$accountName" -g "$resourceGroup" \
    -l "$location" --kind OpenAI --sku S0 --yes
fi

modelsJson=$(az rest \
  --method get \
  --url "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.CognitiveServices/accounts/${accountName}/models?api-version=2023-05-01" \
  -o json)

# Extract candidate versions
echo "$modelsJson" | jq --arg m "$modelName" '[ .[] | select(.name|startswith($m)) | {name, version: .properties.version, sku: (.properties.skuName // .properties.sku?.name)} ]' > filtered.json

if [[ $(jq 'length' filtered.json) -eq 0 ]]; then
  echo "No versions of $modelName found in $location."
  exit 2
fi

echo "Available versions:"
jq '.[]' filtered.json

# Choose first version with a supported SKU precedence
preferredSkus=(GlobalStandard ProvisionedManaged Standard)
chosenVersion=''
chosenSku=''
for sku in \"${preferredSkus[@]}\"; do
  line=$(jq -r --arg sku \"$sku\" '.[] | select(.sku==$sku) | "\(.version) \(.sku)"' filtered.json | head -n1 || true)
  if [[ -n \"$line\" ]]; then
    chosenVersion=$(echo \"$line\" | awk '{print $1}')
    chosenSku=$sku
    break
  fi
done

if [[ -z \"$chosenVersion\" ]]; then
  echo \"No preferred SKU found; picking first:\"
  chosenVersion=$(jq -r '.[0].version' filtered.json)
  chosenSku=$(jq -r '.[0].sku' filtered.json)
fi

echo \"Selected version=$chosenVersion sku=$chosenSku\"

# Export for Bicep parameters file or env
echo \"CHAT_GPT_MODEL_VERSION=$chosenVersion\"
echo \"CHAT_GPT_SKU=$chosenSku\"