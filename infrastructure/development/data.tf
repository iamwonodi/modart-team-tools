# Core's platform contract for this environment: everything this repository
# needs from core, never core's state.
data "aws_ssm_parameter" "platform" {
  name = "/${var.project_name}/platform/config"
}
