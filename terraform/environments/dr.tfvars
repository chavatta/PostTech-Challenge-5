# Site de DR (Warm Standby) — mesma infraestrutura em outra região, com 1 comando:
#   terraform workspace select dr && terraform apply -var-file=environments/dr.tfvars
# Dimensionado menor (FinOps): o espelho fica "morno", cresce só quando ativado.
region       = "us-west-2"
site         = "dr"
node_desired = 1
node_min     = 1
node_max     = 3
