output "application_gateway" {
  value = var.enabled ? {
    id                      = azurerm_application_gateway.this[0].id
    private_ip              = var.private_ip
    frontend_port           = 8080
    hostname_zone           = "moodle.test"
    sku                     = "Standard_v2"
    zones                   = ["1", "2", "3"]
    public_frontend_enabled = false
  } : null
}

output "moodle_dns_records" {
  description = "Taggable private Moodle DNS records created during shared reconciliation."
  value = {
    for slug, record in azurerm_private_dns_a_record.moodle : slug => {
      id   = record.id
      name = record.name
    }
  }
}
