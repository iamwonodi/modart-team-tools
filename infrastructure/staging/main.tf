# ------------------------------------------------------------------------------
# THE TEAM TOOLS IN STAGING
#
# Everything comes from core's platform contract, never from core's state; the
# images, the schedule and the RDS bundle's checksum from tools/.
# ------------------------------------------------------------------------------

module "tools" {
  source = "../../modules/tools-fleet"

  project_name  = var.project_name
  environment   = "staging"
  platform_json = data.aws_ssm_parameter.platform.insecure_value

  images            = jsondecode(file("${path.module}/../../tools/images.json"))
  rds_bundle_sha256 = trimspace(file("${path.module}/../../tools/rds-bundle.sha256"))

  schedule_days       = local.schedule.days
  schedule_start_hour = local.schedule.start_hour
  schedule_stop_hour  = local.schedule.stop_hour
}
