resource "kubernetes_namespace" "monitoring" {
  metadata { 
    name = "monitoring" 
  }
}

# Install ONLY the Prometheus server
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = var.prometheus_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  atomic     = true
  timeout    = 600

  set { 
    name  = "alertmanager.enabled" 
    value = "false" 
  }
  set { 
    name  = "pushgateway.enabled" 
    value = "false" 
  }
  set { 
    name  = "server.resources.requests.memory" 
    value = "64Mi" 
  }
  set { 
    name  = "server.resources.requests.cpu" 
    value = "100m" 
  }
}

# Install ONLY Grafana
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = var.grafana_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  atomic     = true
  timeout    = 600

  set_sensitive {
    name  = "adminPassword"
    value = var.grafana_admin_password
  }
  set { 
    name  = "resources.requests.memory" 
    value = "64Mi" 
  }
  set { 
    name  = "resources.requests.cpu" 
    value = "50m" 
  }
  set { 
    name  = "sidecar.datasources.enabled" 
    value = "false" 
  }
  set { 
    name  = "sidecar.dashboards.enabled" 
    value = "false" 
  }
}
