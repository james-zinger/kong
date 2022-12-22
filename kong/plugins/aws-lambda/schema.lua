-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "aws-lambda",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { timeout = {
          type = "number",
          required = true,
          default = 60000,
        } },
        { keepalive = {
          type = "number",
          required = true,
          default = 60000,
        } },
        { aws_key = {
          type = "string",
          encrypted = true, -- Kong Enterprise-exclusive feature, does nothing in Kong CE
          referenceable = true,
        } },
        { aws_secret = {
          type = "string",
          encrypted = true, -- Kong Enterprise-exclusive feature, does nothing in Kong CE
          referenceable = true,
        } },
        { aws_assume_role_arn = {
          type = "string",
          encrypted = true, -- Kong Enterprise-exclusive feature, does nothing in Kong CE
          referenceable = true,
        } },
        { aws_role_session_name = {
          type = "string",
          default = "kong",
        } },
        { aws_region = typedefs.host },
        { function_name = {
          type = "string",
          required = false,
        } },
        { qualifier = {
          type = "string",
        } },
        { invocation_type = {
          type = "string",
          required = true,
          default = "RequestResponse",
          one_of = { "RequestResponse", "Event", "DryRun" }
        } },
        { log_type = {
          type = "string",
          required = true,
          default = "Tail",
          one_of = { "Tail", "None" }
        } },
        { host = typedefs.host },
        { port = typedefs.port { default = 443 }, },
        { unhandled_status = {
          type = "integer",
          between = { 100, 999 },
        } },
        { forward_request_method = {
          type = "boolean",
          default = false,
        } },
        { forward_request_uri = {
          type = "boolean",
          default = false,
        } },
        { forward_request_headers = {
          type = "boolean",
          default = false,
        } },
        { forward_request_body = {
          type = "boolean",
          default = false,
        } },
        { is_proxy_integration = {
          type = "boolean",
          default = false,
        } },
        { awsgateway_compatible = {
          type = "boolean",
          default = false,
        } },
        { proxy_url = typedefs.url },
        { skip_large_bodies = {
          type = "boolean",
          default = true,
        } },
        { base64_encode_body = {
          type = "boolean",
          default = true,
        } },
        { aws_imds_protocol_version = {
          type = "string",
          required = true,
          default = "v1",
          one_of = { "v1", "v2" }
        } },
      }
    },
  } },
  entity_checks = {
    { mutually_required = { "config.aws_key", "config.aws_secret" } },
    { custom_entity_check = {
        field_sources = { "config.proxy_url" },
        fn = function(entity)
          local proxy_url = entity.config and entity.config.proxy_url

          if type(proxy_url) == "string" then
            local scheme = proxy_url:match("^([^:]+)://")

            if scheme and scheme ~= "http" then
              return nil, "proxy_url scheme must be http"
            end
          end

          return true
        end,
      }
    },
  }
}
