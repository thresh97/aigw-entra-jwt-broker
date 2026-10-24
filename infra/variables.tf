variable "subscription_id" {
  description = "Azure subscription that hosts the Container App and Key Vault. May belong to a different tenant than the Entra tenant that issues the caller tokens."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into. Null creates a new one."
  type        = string
  default     = null
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "name_prefix" {
  description = "Prefix for every resource. Lowercase letters and digits only."
  type        = string
  default     = "aigwentrajwt"
}

variable "entra_tenant_id" {
  description = "Directory (tenant) ID of the Entra tenant that issues the caller tokens."
  type        = string
}

variable "entra_client_id" {
  description = "Application (client) ID of the broker API app registration (the token audience)."
  type        = string
}

variable "entra_app_id_uri" {
  description = "Application ID URI of the broker API app registration. Also accepted as token audience."
  type        = string
  default     = ""
}

variable "portkey_oid" {
  description = "Portkey organisation ID, written into every minted token as portkey_oid."
  type        = string
}

variable "policy" {
  description = "Entra app role to Portkey claims. Key order is the precedence order when a caller holds several roles."
  type = map(object({
    workspace    = string
    config_slug  = string
    config_id    = optional(string)
    scopes       = list(string)
    metadata     = optional(map(string))
    usage_limits = optional(any)
  }))
}

variable "container_image" {
  description = "Public image reference, for example ghcr.io/<owner>/aigw-entra-jwt-broker:<tag> (broker/publish.sh prints it). Null (the first pass) creates everything except the Container App."
  type        = string
  default     = null
}

variable "min_replicas" {
  description = "1 keeps the broker warm (no cold start on token exchange). 0 scales to zero and the first call after idle is slow."
  type        = number
  default     = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
