terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # State local por decisão de projeto: no AWS Academy as credenciais expiram a cada sessão e
  # o ambiente é destruído ao final. O arquivo terraform.tfstate está no .gitignore.
}
