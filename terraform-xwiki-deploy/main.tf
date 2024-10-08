terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.30.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "2.30.0"
    }
  }

  backend "azurerm" {
    key      = "terraform.tfstate"
    use_oidc = true
  }
}

provider "azurerm" {
  use_oidc                   = true
  skip_provider_registration = true
  features {}
}

provider "azuread" {
}

data "azurerm_client_config" "current" {}

# Locals for common tags and naming
locals {
  common_tags = {
    Environment = var.environment
    Project     = "XWiki"
    ManagedBy   = "Terraform"
  }
  resource_prefix = "${var.environment}-xwiki"
}

# Resource Group
data "azurerm_resource_group" "xwiki_rg" {
  name = var.resource_group_name
}

# App Service Plan
resource "azurerm_app_service_plan" "xwiki_plan" {
  name                = "${local.resource_prefix}-asp"
  location            = data.azurerm_resource_group.xwiki_rg.location
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = var.app_service_plan_tier
    size = var.app_service_plan_size
  }

  tags = local.common_tags
}

# App Service
resource "azurerm_app_service" "xwiki_app" {
  name                = "${local.resource_prefix}-app"
  location            = data.azurerm_resource_group.xwiki_rg.location
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name
  app_service_plan_id = azurerm_app_service_plan.xwiki_plan.id

  site_config {
    linux_fx_version = "DOCKER|xwiki:lts-postgres-tomcat"
    always_on        = true
  }

  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "DOCKER_REGISTRY_SERVER_URL"          = "https://index.docker.io"
    "WEBSITES_PORT"                       = "8080"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      site_config[0].linux_fx_version, # Ignore changes to the Docker image tag
    ]
  }
}

resource "azurerm_postgresql_server" "xwiki_db" {
  name                = "${local.resource_prefix}-db"
  location            = data.azurerm_resource_group.xwiki_rg.location
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name

  sku_name = "B_Gen5_1"

  storage_mb                   = 5120
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true

  administrator_login          = var.db_admin_username
  administrator_login_password = var.db_admin_password
  version                      = "11"
  ssl_enforcement_enabled      = true

  tags = local.common_tags
}
# PostgreSQL Database
resource "azurerm_postgresql_database" "xwiki_db" {
  name                = var.db_name
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name
  server_name         = azurerm_postgresql_server.xwiki_db.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}


# Storage Account for XWiki file backups
resource "azurerm_storage_account" "xwiki_storage" {
  name                     = lower(replace("${local.resource_prefix}st", "-", ""))
  resource_group_name      = data.azurerm_resource_group.xwiki_rg.name
  location                 = data.azurerm_resource_group.xwiki_rg.location
  account_tier             = var.storage_account_tier
  account_replication_type = var.storage_account_replication_type

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
  }

  tags = local.common_tags
}

# Blob Container for XWiki file backups
resource "azurerm_storage_container" "xwiki_backups" {
  name                  = var.backup_container_name
  storage_account_name  = azurerm_storage_account.xwiki_storage.name
  container_access_type = "private"
}

# Network Security Group
resource "azurerm_network_security_group" "xwiki_nsg" {
  name                = "${local.resource_prefix}-nsg"
  location            = data.azurerm_resource_group.xwiki_rg.location
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name

  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

# Application Insights
resource "azurerm_application_insights" "xwiki_insights" {
  name                = "${local.resource_prefix}-insights"
  location            = data.azurerm_resource_group.xwiki_rg.location
  resource_group_name = data.azurerm_resource_group.xwiki_rg.name
  application_type    = "web"

  tags = local.common_tags
}
