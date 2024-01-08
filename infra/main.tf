# Create Local Variables to use later, execute bash script
locals {
  storage_account_url         = "https://${azurerm_storage_account.storage.name}.blob.core.windows.net/"
  cognitive_services_endpoint = azurerm_cognitive_account.cvision.endpoint
  vision_api_key              = azurerm_cognitive_account.cvision.primary_access_key
  acr_url                     = "https://${azurerm_container_registry.acr.login_server}/"
  ftp_username                = data.external.ftp_credentials.result["username"]
  ftp_password                = data.external.ftp_credentials.result["password"]
}
data "external" "ftp_credentials" {
  program = ["bash", "${path.module}/find.sh"]
  depends_on = [azurerm_linux_web_app.webapp]
}

output "ftp_username" {
  value     = data.external.ftp_credentials.result["username"]
  sensitive = true
}

output "ftp_password" {
  value     = data.external.ftp_credentials.result["password"]
  sensitive = true
}

# Create Randomness
resource "random_string" "str-name" {
  length  = 5
  upper   = false
  numeric = false
  lower   = true
  special = false
}

# Create a resource group
resource "azurerm_resource_group" "rgdemo" {
  name     = "rg-webvideo"
  location = "northeurope"
}

# Create virtual network
resource "azurerm_virtual_network" "vnetdemo" {
  name                = "vnet-demo"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rgdemo.location
  resource_group_name = azurerm_resource_group.rgdemo.name
}

# Create 2 subnets
resource "azurerm_subnet" "snetdemo" {
  name                 = "snet-demo"
  address_prefixes     = ["10.0.1.0/24"]
  virtual_network_name = azurerm_virtual_network.vnetdemo.name
  resource_group_name  = azurerm_resource_group.rgdemo.name
  service_endpoints    = ["Microsoft.Storage", "Microsoft.ContainerRegistry", "Microsoft.CognitiveServices"]
}

resource "azurerm_subnet" "snetdemo2" {
  name                 = "snet-demo2"
  address_prefixes     = ["10.0.2.0/24"]
  virtual_network_name = azurerm_virtual_network.vnetdemo.name
  resource_group_name  = azurerm_resource_group.rgdemo.name
  service_endpoints    = ["Microsoft.Storage", "Microsoft.ContainerRegistry", "Microsoft.CognitiveServices"]
  delegation {
    name = "delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

# Create a Storage Account 
resource "azurerm_storage_account" "storage" {
  name                     = "s${random_string.str-name.result}01"
  resource_group_name      = azurerm_resource_group.rgdemo.name
  location                 = azurerm_resource_group.rgdemo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Create a Container
resource "azurerm_storage_container" "blob" {
  name                  = "uploads"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "container"
}

# Create Azure Container Registry
resource "azurerm_container_registry" "acr" {
  name                          = "azr${random_string.str-name.result}"
  resource_group_name           = azurerm_resource_group.rgdemo.name
  location                      = azurerm_resource_group.rgdemo.location
  sku                           = "Premium"
  admin_enabled                 = true
  data_endpoint_enabled         = true
  public_network_access_enabled = true
  network_rule_set {
    default_action = "Deny"
    ip_rule {
      action   = "Allow"
      ip_range = "4.210.120.223/32"
    }
  }
}
output "acrname" {
  value = azurerm_container_registry.acr.name
}

# Create an App Service Plan
resource "azurerm_service_plan" "asp" {
  name                = "asp-${random_string.str-name.result}"
  resource_group_name = azurerm_resource_group.rgdemo.name
  location            = azurerm_resource_group.rgdemo.location
  os_type             = "Linux"
  sku_name            = "B3"
}

# WebApp
resource "azurerm_linux_web_app" "webapp" {
  name                = "wv${random_string.str-name.result}"
  location            = azurerm_resource_group.rgdemo.location
  resource_group_name = azurerm_resource_group.rgdemo.name
  service_plan_id     = azurerm_service_plan.asp.id
  logs {
    http_logs {
      file_system {
        retention_in_mb   = 35
        retention_in_days = 2
      }
    }
  }
  site_config {
    always_on              = true
    vnet_route_all_enabled = true

    application_stack {
      docker_image_name        = "videoapp:v20"
      docker_registry_url      = local.acr_url
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }
  app_settings = {
    AZURE_ACCOUNT_URL                   = local.storage_account_url
    AZURE_CONTAINER_NAME                = "uploads"
    COMPUTERVISION_ENDPOINT             = local.cognitive_services_endpoint
    COMPUTERVISION_KEY                  = local.vision_api_key
    DOCKER_ENABLE_CI                    = "true"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "true"
    WEBSITE_PULL_IMAGE_OVER_VNET        = "true"
  }

  identity {
    type = "SystemAssigned"
  }
}

# VNET Integration
resource "azurerm_app_service_virtual_network_swift_connection" "vnetintegrationconnection" {
  app_service_id = azurerm_linux_web_app.webapp.id
  subnet_id      = azurerm_subnet.snetdemo2.id
}

# WebHook
resource "azurerm_container_registry_webhook" "whook" {
  actions             = ["push"]
  location            = azurerm_resource_group.rgdemo.location
  name                = "wh${random_string.str-name.result}"
  registry_name       = azurerm_container_registry.acr.name
  resource_group_name = azurerm_resource_group.rgdemo.name
  scope               = "videoapp:v20"
  service_uri         = "https://${local.ftp_username}:${local.ftp_password}@${azurerm_linux_web_app.webapp.name}.scm.azurewebsites.net/api/registry/webhook"
  depends_on          = [azurerm_linux_web_app.webapp]
}

# Create Computer Vision
resource "azurerm_cognitive_account" "cvision" {
  name                  = "ai-${random_string.str-name.result}01"
  location              = azurerm_resource_group.rgdemo.location
  resource_group_name   = azurerm_resource_group.rgdemo.name
  kind                  = "ComputerVision"
  custom_subdomain_name = "ai-${random_string.str-name.result}01"

  sku_name = "F0"
  identity {
    type = "SystemAssigned"
  }
}

# Private DNS
resource "azurerm_private_dns_zone" "blobzone" {
  name                = "privatelink.blob.core.azure.com"
  resource_group_name = azurerm_resource_group.rgdemo.name
}

resource "azurerm_private_endpoint" "blobprv" {
  location            = azurerm_resource_group.rgdemo.location
  name                = "spriv${random_string.str-name.result}"
  resource_group_name = azurerm_resource_group.rgdemo.name
  subnet_id           = azurerm_subnet.snetdemo.id
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blobzone.id]
  }
  private_service_connection {
    is_manual_connection           = false
    name                           = "storpriv"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["blob"]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "bloblink" {
  name                  = "main"
  resource_group_name   = azurerm_resource_group.rgdemo.name
  private_dns_zone_name = azurerm_private_dns_zone.blobzone.name
  virtual_network_id    = azurerm_virtual_network.vnetdemo.id
}

resource "azurerm_private_dns_zone" "aizone" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = azurerm_resource_group.rgdemo.name
}

resource "azurerm_private_endpoint" "visionpriv" {
  location            = azurerm_resource_group.rgdemo.location
  name                = "vis${random_string.str-name.result}"
  resource_group_name = azurerm_resource_group.rgdemo.name
  subnet_id           = azurerm_subnet.snetdemo.id
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.aizone.id]
  }
  private_service_connection {
    is_manual_connection           = false
    name                           = "visonpriv"
    private_connection_resource_id = azurerm_cognitive_account.cvision.id
    subresource_names              = ["account"]
  }
}
resource "azurerm_private_dns_zone_virtual_network_link" "ailink" {
  name                  = "main"
  resource_group_name   = azurerm_resource_group.rgdemo.name
  private_dns_zone_name = azurerm_private_dns_zone.aizone.name
  virtual_network_id    = azurerm_virtual_network.vnetdemo.id
}

resource "azurerm_private_dns_zone" "acrzone" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.rgdemo.name
}
resource "azurerm_private_endpoint" "acrpriv" {
  location            = azurerm_resource_group.rgdemo.location
  name                = "acr${random_string.str-name.result}"
  resource_group_name = azurerm_resource_group.rgdemo.name
  subnet_id           = azurerm_subnet.snetdemo.id
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acrzone.id]
  }
  private_service_connection {
    is_manual_connection           = false
    name                           = "acrpriv"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
  }
}
resource "azurerm_private_dns_zone_virtual_network_link" "acrlink" {
  name                  = "main"
  resource_group_name   = azurerm_resource_group.rgdemo.name
  private_dns_zone_name = azurerm_private_dns_zone.acrzone.name
  virtual_network_id    = azurerm_virtual_network.vnetdemo.id
}
# Assign RBAC Role to WebApp
data "azurerm_subscription" "current" {}

resource "azurerm_role_assignment" "rbac1" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_web_app.webapp.identity[0].principal_id
}



