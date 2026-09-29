# This environment's start and stop times, from tools/schedule.json.
locals {
  schedule = jsondecode(file("${path.module}/../../tools/schedule.json")).production
}
