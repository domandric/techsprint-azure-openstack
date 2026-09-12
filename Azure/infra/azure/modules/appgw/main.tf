resource "terraform_data" "guardrails" {
  input = var.enabled

  lifecycle {
    precondition {
      condition     = !var.enabled || length(var.tenant_backends) > 0
      error_message = "A private Application Gateway is created only after at least one tenant backend exists; run shared reconciliation after tenant roots."
    }

    precondition {
      condition     = length(distinct([for backend in values(var.tenant_backends) : 100 + backend.network_slot])) == length(var.tenant_backends)
      error_message = "Application Gateway rule priorities (100 + network_slot) must be unique."
    }
  }
}

resource "azurerm_application_gateway" "this" {
  count = var.enabled ? 1 : 0

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  http2_enabled       = false
  zones               = ["1", "2", "3"]
  tags                = var.tags

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip"
    subnet_id = var.subnet_id
  }

  frontend_port {
    name = "frontend-8080"
    port = 8080
  }

  frontend_ip_configuration {
    name                          = "frontend-private"
    subnet_id                     = var.subnet_id
    private_ip_address            = var.private_ip
    private_ip_address_allocation = "Static"
  }

  dynamic "backend_address_pool" {
    for_each = var.tenant_backends
    content {
      name         = "pool-${backend_address_pool.key}"
      ip_addresses = [backend_address_pool.value.app01_private_ip, backend_address_pool.value.app02_private_ip]
    }
  }

  dynamic "probe" {
    for_each = var.tenant_backends
    content {
      name                                      = "probe-${probe.key}"
      protocol                                  = "Http"
      path                                      = "/readyz"
      host                                      = "${probe.value.slug}.moodle.test"
      interval                                  = 10
      timeout                                   = 10
      unhealthy_threshold                       = 3
      pick_host_name_from_backend_http_settings = false

      match {
        status_code = ["200-399"]
      }
    }
  }

  dynamic "backend_http_settings" {
    for_each = var.tenant_backends
    content {
      name                                = "http-${backend_http_settings.key}"
      cookie_based_affinity               = "Disabled"
      affinity_cookie_name                = "ApplicationGatewayAffinity"
      port                                = 80
      protocol                            = "Http"
      request_timeout                     = 30
      host_name                           = "${backend_http_settings.value.slug}.moodle.test"
      pick_host_name_from_backend_address = false
      probe_name                          = "probe-${backend_http_settings.key}"

      connection_draining {
        enabled           = true
        drain_timeout_sec = 30
      }
    }
  }

  dynamic "http_listener" {
    for_each = var.tenant_backends
    content {
      name                           = "listener-${http_listener.key}"
      frontend_ip_configuration_name = "frontend-private"
      frontend_port_name             = "frontend-8080"
      protocol                       = "Http"
      host_name                      = "${http_listener.value.slug}.moodle.test"
    }
  }

  dynamic "request_routing_rule" {
    for_each = var.tenant_backends
    content {
      name                       = "rule-${request_routing_rule.key}"
      rule_type                  = "Basic"
      priority                   = 100 + request_routing_rule.value.network_slot
      http_listener_name         = "listener-${request_routing_rule.key}"
      backend_address_pool_name  = "pool-${request_routing_rule.key}"
      backend_http_settings_name = "http-${request_routing_rule.key}"
    }
  }

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_private_dns_a_record" "moodle" {
  for_each = var.enabled ? var.tenant_backends : {}

  name                = each.value.slug
  zone_name           = var.moodle_private_dns_zone_name
  resource_group_name = var.moodle_private_dns_zone_resource_group_name
  ttl                 = 60
  records             = [var.private_ip]
  tags                = var.tags

  depends_on = [azurerm_application_gateway.this]
}
