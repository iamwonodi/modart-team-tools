terraform {
  backend "s3" {
    # The environment's state bucket, created by core's bootstrap script. Named
    # <project>-<environment>-tfstate. Backend blocks cannot use variables, so
    # scripts/init-tools.sh writes the bucket and region.
    bucket = "modart-development-tfstate"

    # Core's tools-role may read and write ONLY keys under team-tools/, so the
    # key must stay in that shape.
    key = "team-tools/terraform.tfstate"

    region       = "af-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB
  }
}
