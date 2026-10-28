resource "local_file" "worker_gateway" {
  filename = "kubernetes/worker/gateway.yaml"
  content = templatefile("gateway.tmpl",
    {
      DOMAIN = azurerm_dns_zone.apps.name
    }
  )
}