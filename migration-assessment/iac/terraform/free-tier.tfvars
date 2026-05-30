# free-account overlay: single small node, no separate user pool, ACR Basic, southeast asia.
# apply with: terraform apply -var-file=free-tier.tfvars
location = "southeastasia"

system_node_size       = "Standard_B2s_v2" # 2 vCPU / 8 GB (Bsv2 is allowed on this sub)
system_autoscaling     = false
system_node_count      = 2     # 2 x B2s_v2 = 4 vCPU (the regional cap); 1 node can't fit the AKS add-ons + app
system_only_critical   = false # app runs on the system pool (no separate user pool)
enable_user_pool       = false
zones                  = [] # B-series single node, no zonal placement
acr_sku                = "Basic"
local_account_disabled = false # allow local kubeconfig for the demo (Entra-only is the prod default)
