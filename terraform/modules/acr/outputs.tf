output "registry_id" {
  value = azurerm_container_registry.this.id
}

output "login_server" {
  value = azurerm_container_registry.this.login_server
}

output "registry_name" {
  value = azurerm_container_registry.this.name
}
