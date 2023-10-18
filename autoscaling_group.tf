resource "aws_iam_service_linked_role" "this" {
  aws_service_name = "autoscaling.amazonaws.com"
  # use hash if name is too long to make things unique
  custom_suffix    = length("AWSServiceRoleForAutoScaling_") + length(local.module_resource_name) > 64 ? join("_", [ substr(local.module_resource_name, 0, 53 - length("AWSServiceRoleForAutoScaling_")), random_string.this.result ]) : local.module_resource_name

  lifecycle {
    ignore_changes = [ custom_suffix ] # along with the random_string a bit of a hack to use autogenerated names but keep things stable
  }
}

resource "random_string" "this" {
  length           = 9
  special          = false
}

resource "aws_autoscaling_group" "this" {
  name                    = local.module_resource_name
  service_linked_role_arn = aws_iam_service_linked_role.this.arn

  wait_for_capacity_timeout = 0 # disabled to prevent issues with policies depending on asg arn

  desired_capacity  = var.initial_amount_of_pods
  max_size = var.initial_amount_of_pods
  min_size = var.initial_amount_of_pods

  protect_from_scale_in = false

  capacity_rebalance = false

  # Todo: parameterize for spot instances later on
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = "$Latest"
      }

      override {
        instance_type     = var.ec2_instance_type
        weighted_capacity = "1"
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = 0   # must be set to 0 if we want initial_lifecycle hooks, bug in ASG?
      on_demand_percentage_above_base_capacity = 100 # remediate 0 value above
      spot_allocation_strategy                 = "lowest-price"
      spot_max_price                           = "" # = same as on-demand
    }
  }

  health_check_type = "EC2"

  vpc_zone_identifier = var.subnet_ids
  target_group_arns = var.target_group_arns

  dynamic "initial_lifecycle_hook" {
    for_each = merge(merge({ for k, v in var.lifecycle_hooks : k => v }
    , var.user_data_completion_hook ? tomap({
      "userdata" = {
        launch_lifecycle = true
        notification_metadata = null
        timeout_in_seconds = var.user_data_lifecyclehook_timeout
      }
    }) : {}), local.use_floating_ip ? tomap({
      "${local.elastic_ip_lifecyclehook}" = {
        launch_lifecycle = true
        timeout_in_seconds = 60
        notification_metadata = jsonencode({
        "allocation_id": length(aws_eip.this) > 0 ? aws_eip.this[0].allocation_id : data.aws_eip.own_eip[0].id
      })
      }
    }) : {})

    content {
      name                 = initial_lifecycle_hook.key
      default_result       = "ABANDON"
      heartbeat_timeout    = initial_lifecycle_hook.value.timeout_in_seconds
      lifecycle_transition = initial_lifecycle_hook.value.launch_lifecycle ? "autoscaling:EC2_INSTANCE_LAUNCHING" : "autoscaling:EC2_INSTANCE_TERMINATING"
      notification_metadata = initial_lifecycle_hook.value.notification_metadata
    }
  }

  tag {
    key                 = "Name"
    value               = local.module_resource_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.additional_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity, max_size, min_size]
  }
}
