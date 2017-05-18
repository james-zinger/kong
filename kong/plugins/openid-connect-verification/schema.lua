return {
  no_consumer    = true,
  fields         = {
    issuer       = {
      required   = true,
      type       = "url",
    },
    param_name   = {
      required   = false,
      type       = "string",
      default    = "id_token",
    },
    param_type   = {
      required   = false,
      type       = "array",
      enum       = { "query", "header", "body" },
      default    = { "query", "header", "body" },
    },
    jwk_header   = {
      required   = false,
      type       = "string",
    },
    claims       = {
      required   = false,
      type       = "array",
      enum       = { "iss", "sub", "aud", "azp", "exp", "iat", "auth_time", "at_hash", "alg", "nbf", "hd" },
      default    = { "iss", "sub", "aud", "azp", "exp", "iat" },
    },
    audiences    = {
      required   = false,
      type       = "array",
    },
    domains      = {
      required   = false,
      type       = "array",
    },
    max_age      = {
      required   = false,
      type       = "number",
    },
    leeway       = {
      required   = false,
      type       = "number",
      default    = 0,
    },
    http_version = {
      required   = false,
      type       = "number",
      enum       = { 1.0, 1.1 },
      default    = 1.1,
    },
    ssl_verify   = {
      required   = false,
      type       = "boolean",
      default    = true,
    },
    timeout      = {
      required   = false,
      type       = "number",
      default    = 10000,
    },
  },
}
