terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.49.0"
    }
    azuread = {
      source = "hashicorp/azuread"
        version = "~> 2.0"
    }
  }
}
provider "azuread" {

}
provider "azurerm" {
  features {}
}