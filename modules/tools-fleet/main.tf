# ------------------------------------------------------------------------------
# THE TEAM TOOLS
#
# DbGate and CloudBeaver on one disposable spot server per environment, in the
# private subnets, wearing core's team-tools security group (which the
# databases admit) beside its own. It runs on a schedule, Lagos time, and can
# be started by hand (the Start tools workflow), switching off two hours later.
#
# Where core runs a front door (development, staging), each tool has a web
# address, <tool>.<domain>, on the private load balancer, behind the Cognito
# sign-in. In production the tools have no address: people reach them through
# a Session Manager tunnel.
#
# Everything here is tagged Service=team-tools (the provider's default tags),
# which is what core's tools-role lets this repository create and change.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# The servers' own security group
# ------------------------------------------------------------------------------

resource "aws_security_group" "hosts" {
  name        = "${local.name}-hosts"
  description = "The team tools servers: reached by the private load balancer only."
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name}-hosts" }

  lifecycle {
    create_before_destroy = true
  }
}

# Terraform removes AWS's default allow-all outbound rule, and the servers start
# connections of their own: Docker Hub and the RDS bundle through the NAT, the
# databases, and SSM.
resource "aws_vpc_security_group_egress_rule" "hosts" {
  security_group_id = aws_security_group.hosts.id
  description       = "Allow the tools to reach the databases, the images and SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "from_load_balancer" {
  for_each = local.front_door ? { dbgate = 3000, cloudbeaver = 8978 } : {}

  security_group_id            = aws_security_group.hosts.id
  referenced_security_group_id = local.platform.tiers.private.alb_security_group_id
  description                  = "Allow the private load balancer to reach ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# ------------------------------------------------------------------------------
# The servers' role: the SSM agent (the tunnel, and management), capped by
# core's permissions boundary
# ------------------------------------------------------------------------------

resource "aws_iam_role" "hosts" {
  name                 = "${local.name}-hosts"
  path                 = local.iam_path
  permissions_boundary = local.boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.hosts.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "hosts" {
  name = "${local.name}-hosts"
  path = local.iam_path
  role = aws_iam_role.hosts.name
}

# ------------------------------------------------------------------------------
# Launch template and Auto Scaling group
# ------------------------------------------------------------------------------

resource "aws_launch_template" "this" {
  name        = local.name
  description = "The team tools: DbGate and CloudBeaver."

  # Core's golden image, read from its parameter at launch, so a rebuilt image
  # reaches the tools at their next start.
  image_id = "resolve:ssm:${local.ami_parameter}"

  iam_instance_profile {
    arn = aws_iam_instance_profile.hosts.arn
  }

  vpc_security_group_ids = [aws_security_group.hosts.id, local.tools_sg_id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.name, Service = local.tag }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = local.name, Service = local.tag }
  }

  lifecycle {
    precondition {
      condition     = length(local.user_data) <= 16384
      error_message = "The start-up script is ${length(local.user_data)} bytes, over EC2's 16 KB for user data."
    }
  }
}

resource "aws_autoscaling_group" "this" {
  name                = local.asg_name
  vpc_zone_identifier = local.subnet_ids

  # Off until the schedule or the Start button says otherwise.
  min_size         = 0
  max_size         = 1
  desired_capacity = 0

  health_check_type = local.front_door ? "ELB" : "EC2"
  # The first start pulls both images from Docker Hub.
  health_check_grace_period = 600

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = aws_launch_template.this.latest_version
      }

      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }

  lifecycle {
    # The schedule and the Start button change it; Terraform does not.
    ignore_changes = [desired_capacity]
  }
}

# ------------------------------------------------------------------------------
# The schedule, Lagos time. The Start tools workflow starts it outside these
# hours and books a one-off stop two hours later.
# ------------------------------------------------------------------------------

resource "aws_autoscaling_schedule" "start" {
  scheduled_action_name  = "scheduled-start"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 ${var.schedule_start_hour} * * ${var.schedule_days}"
  time_zone              = "Africa/Lagos"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 1
}

resource "aws_autoscaling_schedule" "stop" {
  scheduled_action_name  = "scheduled-stop"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 ${var.schedule_stop_hour} * * ${var.schedule_days}"
  time_zone              = "Africa/Lagos"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
}

# ------------------------------------------------------------------------------
# The front door (development, staging): <tool>.<domain> on the private load
# balancer, behind the Cognito sign-in. Rules match the host exactly, so their
# order does not matter and AWS assigns the priority, as for services.
# ------------------------------------------------------------------------------

resource "aws_lb_target_group" "tool" {
  for_each = local.front_door ? local.tools : {}

  # Target group names are at most 32 characters, which a long project name
  # would exceed; AWS completes the prefix. Core's tools-role scopes target
  # groups by their Service tag, not by name.
  name_prefix = each.value.name_prefix
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  health_check {
    path                = "/"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
  }
}

resource "aws_autoscaling_traffic_source_attachment" "tool" {
  for_each = aws_lb_target_group.tool

  autoscaling_group_name = aws_autoscaling_group.this.name

  traffic_source {
    identifier = each.value.arn
    type       = "elbv2"
  }
}

resource "aws_cognito_user_pool_client" "tools" {
  count = local.front_door ? 1 : 0

  name         = local.name
  user_pool_id = local.front_door_conf.user_pool_id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = [for tool in keys(local.tools) : "https://${tool}.${local.domain_name}/oauth2/idpresponse"]
}

# Managed login needs a style per app client; Cognito's own look.
resource "aws_cognito_managed_login_branding" "tools" {
  count = local.front_door ? 1 : 0

  user_pool_id                = local.front_door_conf.user_pool_id
  client_id                   = aws_cognito_user_pool_client.tools[0].id
  use_cognito_provided_values = true
}

resource "aws_lb_listener_rule" "tool" {
  for_each = local.front_door ? local.tools : {}

  listener_arn = local.platform.tiers.private.listener_arn

  action {
    type = "authenticate-cognito"

    authenticate_cognito {
      user_pool_arn       = local.front_door_conf.user_pool_arn
      user_pool_client_id = aws_cognito_user_pool_client.tools[0].id
      user_pool_domain    = local.front_door_conf.domain
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tool[each.key].arn
  }

  condition {
    host_header {
      values = ["${each.key}.${local.domain_name}"]
    }
  }
}
