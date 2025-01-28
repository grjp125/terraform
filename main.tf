resource "azurerm_resource_group" "rg-avd" {
  name     = "AVD-RG"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "AVD_VNET"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "defaultSubnet" {
  name           = "AVD_SUBNET"
  resource_group_name = azurerm_resource_group.rg-avd.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes = ["10.0.0.0/24"]
}

resource "azurerm_public_ip" "pip" {
  allocation_method   = "Static"
  count=2
  name                = "AVD-PIP-${count.index}"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "AVD-NSG"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name
  security_rule {
    name                       = "allow-rdp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = 3389
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.defaultSubnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "nic_association" {
  network_interface_id      = azurerm_network_interface.sessionhost_nic.*.id[count.index]
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "time_rotating" "avd_token" {
  rotation_days = 30
}

resource "azurerm_virtual_desktop_host_pool" "avd-hp" {
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name

  name                     = "AVD-HP"
  friendly_name            = "rjpool"
  validate_environment     = true
  start_vm_on_connect      = true
  custom_rdp_properties    = "enablerdsaadauth:i:1;audiocapturemode:i:1;audiomode:i:0;enablecredsspsupport:i:1;enablerdsaadauth:i:1;videoplaybackmode:i:1;devicestoredirect:s:*;drivestoredirect:s:*;redirectclipboard:i:1;redirectcomports:i:1;redirectprinters:i:1;redirectsmartcards:i:1;redirectwebauthn:i:1;usbdevicestoredirect:s:*;use multimon:i:1"
  description              = "rj host-pool demo"
  type                     = "Pooled"
  maximum_sessions_allowed = 10
  load_balancer_type       = "BreadthFirst"
}


resource "azurerm_virtual_desktop_host_pool_registration_info" "registration_info" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.avd-hp.id
  expiration_date = var.rfc3339
}

resource "azurerm_virtual_desktop_application_group" "desktopapp" {
  name                = "AVD-DAG"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name
  type          = "Desktop"
  host_pool_id  = azurerm_virtual_desktop_host_pool.avd-hp.id
  friendly_name = "avd-appgroup"
  description   = "rj avd application group"
}

resource "azurerm_virtual_desktop_workspace" "workspace" {
  name                = "AVD-WORKSPACE"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name
  friendly_name = "Workspace AVD"
  description   = "Work Purporse"
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "workspaceremoteapp" {
  workspace_id         = azurerm_virtual_desktop_workspace.workspace.id
  application_group_id = azurerm_virtual_desktop_application_group.desktopapp.id
}


resource "azurerm_network_interface" "sessionhost_nic" {
    count=2
  name                = "AVD-NIC-${count.index}"
  location            = azurerm_resource_group.rg-avd.location
  resource_group_name = azurerm_resource_group.rg-avd.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.defaultSubnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.pip.*.id[count.index]
  }
}

resource "azurerm_windows_virtual_machine" "sessionhost" {
  depends_on = [
      azurerm_network_interface.sessionhost_nic
  ]
  count=2
  name                = "AVD-VM-${count.index}"
  resource_group_name = azurerm_resource_group.rg-avd.name
  location            = azurerm_resource_group.rg-avd.location
  size                = "Standard_D2s_v3"
  admin_username      = "adminuser"
  admin_password      = "P@ssW0rd1234"
  provision_vm_agent = true
  license_type = "Windows_Client"
  
  network_interface_ids = [azurerm_network_interface.sessionhost_nic.*.id[count.index]]

  additional_capabilities {
  }
  boot_diagnostics {
  }
  identity {
    type = "SystemAssigned"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    offer     = "office-365"
    publisher = "microsoftwindowsdesktop"
    sku       = "win10-22h2-avd-m365-g2"
    version   = "latest"
  }
  secure_boot_enabled = true
}

locals {
  registration_token = azurerm_virtual_desktop_host_pool_registration_info.registration_info.token
  shutdown_command     = "shutdown -r -t 10"
  exit_code_hack       = "exit 0"
  commandtorun         = "New-Item -Path HKLM:/SOFTWARE/Microsoft/RDInfraAgent/AADJPrivate"
  powershell_command   = "${local.commandtorun}; ${local.shutdown_command}; ${local.exit_code_hack}"
}

resource "azurerm_virtual_machine_extension" "AVDModule" {
  depends_on = [
      azurerm_windows_virtual_machine.sessionhost
  ]
  count = 2
  name                 = "Microsoft.PowerShell.DSC"
  virtual_machine_id   = azurerm_windows_virtual_machine.sessionhost.*.id[count.index]
  publisher            = "Microsoft.Powershell"
  type                 = "DSC"
  type_handler_version = "2.73"
  settings = <<-SETTINGS
    {
        "modulesUrl": "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_11-22-2021.zip",
        "ConfigurationFunction": "Configuration.ps1\\AddSessionHost",
        "Properties" : {
          "hostPoolName" : "${azurerm_virtual_desktop_host_pool.avd-hp.name}",
          "aadJoin": true
        }
    }
SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
  {
    "properties": {
      "registrationInfoToken": "${local.registration_token}"
    }
  }
PROTECTED_SETTINGS

}
resource "azurerm_virtual_machine_extension" "AADLoginForWindows" {
  depends_on = [
      azurerm_windows_virtual_machine.sessionhost,
        azurerm_virtual_machine_extension.AVDModule
  ]
  count = 2
  name                 = "AADLoginForWindows"
  virtual_machine_id   = azurerm_windows_virtual_machine.sessionhost.*.id[count.index]
  publisher            = "Microsoft.Azure.ActiveDirectory"
  type                 = "AADLoginForWindows"
  type_handler_version = "2.0"
  auto_upgrade_minor_version = true
}
resource "azurerm_virtual_machine_extension" "addaadjprivate" {
    depends_on = [    azurerm_virtual_machine_extension.AADLoginForWindows
    ]
    count = 2
  name                 = "AADJPRIVATE"
  virtual_machine_id =    azurerm_windows_virtual_machine.sessionhost.*.id[count.index]
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = <<SETTINGS
    {
        "commandToExecute": "powershell.exe -Command \"${local.powershell_command}\""
    }
SETTINGS
}
  
