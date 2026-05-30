terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
  # Remote state for CI. Partial config - storage_account_name passed via -backend-config
  # at init time (it carries a random suffix and isn't worth pinning in code).
  # use_azuread_auth: authenticate to the blob endpoint via the OIDC AAD token instead of
  # storage access keys, so the CI identity doesn't need Microsoft.Storage/storageAccounts/listKeys.
  # Bootstrap: see iac/terraform/README.md.
  backend "azurerm" {
    resource_group_name = "tfstate-rg"
    container_name      = "tfstate"
    key                 = "petclinic.aks.tfstate"
    use_azuread_auth    = true
  }
}

provider "azurerm" {
  # subscription_id comes from ARM_SUBSCRIPTION_ID (or TF_VAR_subscription_id).
  # do not auto-register every RP (slow on a fresh sub); we register the needed ones manually.
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {}
}
