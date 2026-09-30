terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "4.40.1"
    }
  }

  backend "gcs" {
    # bucket is supplied with -backend-config=bucket=... at init time.
    prefix = "comma-grafana-staging"
  }
}

provider "grafana" {
  url = "https://afksurf.grafana.net"
}
