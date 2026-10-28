resource "local_file" "worker_gateway" {
  filename = "kubernetes/worker/gateway.yaml"
  content = templatefile("gateway.tmpl",
    {
      DOMAIN                        = azurerm_dns_zone.apps.name
      PROVIDER_KUBERNETES_OBJECT_ID = azurerm_user_assigned_identity.provider_kubernetes.principal_id
    }
  )
}