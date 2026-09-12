# Bootstrap owns the admin-scoped provider. Other roots and provider-less
# modules inherit a root provider scoped by OS_PROJECT_ID or clouds.yaml.
provider "openstack" {
  cloud  = var.cloud != "" ? var.cloud : null
  region = var.region
}
