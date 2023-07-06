export LOCATION=westus2
export RESOURCE_GROUP_NAME=aks-lts-prow
az group create --name $RESOURCE_GROUP_NAME --location $LOCATION
az deployment group create \
  --resource-group $RESOURCE_GROUP_NAME \
  --template-file prow-cluster.bicep \
  --parameters aks_cluster_region=$LOCATION
