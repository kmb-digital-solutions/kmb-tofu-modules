terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
      # ACM certificates consumed by CloudFront MUST live in us-east-1
      # regardless of where the rest of the stack runs. Callers declare an
      # `aws.us_east_1` provider alias and pass it through the providers
      # meta-argument; in stacks that already run in us-east-1 the alias is
      # the same as the default provider.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
