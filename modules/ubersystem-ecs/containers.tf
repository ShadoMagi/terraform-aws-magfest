locals {
    container_common = {
        "healthCheck": {
          "retries": 3,
          "command": [
            "CMD-SHELL",
            "/app/plugins/uber/healthcheck.sh"
          ],
          "timeout": 5,
          "interval": 30,
          "startPeriod": 60
        },
        "environment": [
            {
                "name": "CERT_NAME",
                "value": "ssl"
            },
            {
                "name": "VIRTUAL_HOST",
                "value": var.hostname
            },
            {
                "name": "SESSION_HOST",
                "value": "${data.aws_elasticache_cluster.redis.cache_nodes.0.address}"
            },
            {
                "name": "SESSION_PREFIX",
                "value": var.prefix
            },
            {
                "name": "BROKER_HOST",
                "value": "${data.aws_elasticache_cluster.redis.cache_nodes.0.address}"
            },
            {
                "name": "BROKER_PROTOCOL",
                "value": "redis"
            },
            {
                "name": "BROKER_PORT",
                "value": "6379"
            },
            {
                "name": "BROKER_USER",
                "value": ""
            },
            {
                "name": "BROKER_PASS",
                "value": ""
            },
            {
                "name": "BROKER_VHOST",
                "value": "0"
            },
            {
                "name": "BROKER_PREFIX",
                "value": "${var.prefix}-"
            },
            {
                "name": "DB_CONNECTION_STRING",
                "value": "postgresql://${var.uber_db_username}:${aws_secretsmanager_secret_version.password.secret_string}@${var.db_endpoint}/${var.uber_db_name}"
            },
            {
                "name": "UBERSYSTEM_CONFIG_VERSION",
                "value": sha256(aws_secretsmanager_secret_version.current_config.secret_string)
            }
        ],
        "secrets": [
          {
            "name": "UBERSYSTEM_CONFIG",
            "valueFrom": aws_secretsmanager_secret.uber_config.arn
          },
          {
            "name": "UBERSYSTEM_SECRETS",
            "valueFrom": aws_secretsmanager_secret.uber_secret.arn
          }
        ],
        "mountPoints": [
            {
                "sourceVolume": "static",
                "containerPath": "/app/plugins/uber/uploaded_files",
                "readOnly": false
            }
        ]
    }
    container_web = {
        "cpu": var.web_cpu,
        "portMappings": [
            {
                "protocol": "tcp",
                "containerPort": 8282
            }
        ],
        "image": "${var.ubersystem_container}@sha256:${module.uber_image.docker_digest}",
        "name": "web",
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/Uber/${var.prefix}/web/",
                "awslogs-region": "${var.region}",
                "awslogs-stream-prefix": "web",
                "awslogs-create-group": "true"
            }
        },
    }
    container_celery_beat = {
        "cpu": var.celery_beat_cpu,
        "command": [
            "celery-beat"
        ],
        "image": "${var.ubersystem_container}@sha256:${module.uber_image.docker_digest}",
        "name": "celery-beats",
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/Uber/${var.prefix}/celery_beat/",
                "awslogs-region": "${var.region}",
                "awslogs-stream-prefix": "beats",
                "awslogs-create-group": "true"
            }
        }
    }
    container_celery_worker = {
        "cpu": var.celery_cpu,
        "image": "${var.ubersystem_container}@sha256:${module.uber_image.docker_digest}",
        "command": [
             "celery-worker"
        ],
        "name": "celery-worker",
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/Uber/${var.prefix}/celery_worker/",
                "awslogs-region": "${var.region}",
                "awslogs-stream-prefix": "celery",
                "awslogs-create-group": "true"
            }
        }
    }
}

resource "aws_secretsmanager_secret" "uber_config" {
  name = "${var.prefix}-uber-config"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "current_config" {
  secret_id = aws_secretsmanager_secret.uber_config.id
  secret_string = var.ubersystem_config
}

# -------------------------------------------------------------------
# MAGFest Ubersystem Supporting Services (Web / Combined)
# -------------------------------------------------------------------

resource "aws_ecs_service" "ubersystem_web" {
  name                   = "${var.prefix}_web"
  cluster                = var.ecs_cluster
  task_definition        = aws_ecs_task_definition.ubersystem_web.arn
  desired_count          = var.web_count
  enable_execute_command = true
  launch_type            = "EC2"

  load_balancer {
    target_group_arn = aws_lb_target_group.ubersystem_http.arn
    container_name   = "web"
    container_port   = 8282
  }
}

resource "aws_ecs_task_definition" "ubersystem_web" {
  family                    = "${var.prefix}_web"
  container_definitions     = jsonencode(
    [
      merge(local.container_common, local.container_web)
    ]
  )

  volume {
    name = "static"

    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.uber.id
      }
    }
  }

  memory                    = var.web_ram
  network_mode              = "bridge"
  execution_role_arn        = var.ecs_task_role

  task_role_arn = var.ecs_task_role
}

# -------------------------------------------------------------------
# MAGFest Ubersystem Containers (celery)
# -------------------------------------------------------------------

resource "aws_ecs_service" "ubersystem_celery_beat" {
  count = var.enable_celery ? 1 : 0
  name                   = "${var.prefix}_beats"
  cluster                = var.ecs_cluster
  task_definition        = aws_ecs_task_definition.ubersystem_celery_beat.arn
  desired_count          = 1
  enable_execute_command = true
  launch_type            = "EC2"
}

resource "aws_ecs_task_definition" "ubersystem_celery_beat" {
  family                    = "${var.prefix}_beats"
  container_definitions     = jsonencode(
    [
      merge(local.container_common, local.container_celery_beat)
    ]
  )

  volume {
    name = "static"

    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.uber.id
      }
    }
  }

  memory                    = var.celery_beat_ram
  network_mode              = "bridge"
  execution_role_arn        = var.ecs_task_role
  task_role_arn             = var.ecs_task_role
}

resource "aws_ecs_service" "ubersystem_celery_worker" {
  count = var.enable_celery ? 1 : 0
  name                   = "${var.prefix}_worker"
  cluster                = var.ecs_cluster
  task_definition        = aws_ecs_task_definition.ubersystem_celery_worker.arn
  desired_count          = var.celery_count
  enable_execute_command = true
  launch_type            = "EC2"
}

resource "aws_ecs_task_definition" "ubersystem_celery_worker" {
  family                    = "${var.prefix}_worker"
  container_definitions     = jsonencode(
    [
      merge(local.container_common, local.container_celery_worker)
    ]
  )

  volume {
    name = "static"

    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.uber.id
      }
    }
  }

  memory                    = var.celery_ram
  network_mode              = "bridge"
  execution_role_arn        = var.ecs_task_role
  task_role_arn             = var.ecs_task_role
}
