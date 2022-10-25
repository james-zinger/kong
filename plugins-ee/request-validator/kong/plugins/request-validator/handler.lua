-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson = require("cjson.safe").new()
local lrucache = require "resty.lrucache"
local pl_tablex = require "pl.tablex"
local deserialize = require "resty.openapi3.deserializer"
local validators = require "kong.plugins.request-validator.validators"
local meta = require "kong.meta"

local EMPTY = pl_tablex.readonly({})
local DENY_BODY_MESSAGE = "request body doesn't conform to schema"
local DENY_BODY_MESSAGE_CT = "specified Content-Type is not allowed"
local DENY_PARAM_MESSAGE = "request param doesn't conform to schema"

local kong = kong
local json_decode = cjson.decode
local ngx_req_read_body = ngx.req.read_body
local ngx_req_get_body_data = ngx.req.get_body_data
local req_get_headers = ngx.req.get_headers
local req_get_uri_args = ngx.req.get_uri_args
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ipairs = ipairs
local setmetatable = setmetatable
local ngx_null = ngx.null
local string_find = string.find
local fmt = string.format
local table_insert = table.insert
local lower = string.lower

cjson.decode_array_with_array_mt(true)


local media_type_pattern = [[(.+)\/([^ ;]+)]]
local parameter_pattern = [[;\s*(?<param>[^= ]+)=(?<value>[^; ]+)]]

local function parse_mime_type(mime_type)
  local type, sub_type, params = nil, nil, nil

  local r = ngx_re_match(mime_type, media_type_pattern, "ajo")
  if not r then
    return type, sub_type, params
  end

  type = lower(r[1]) -- type is case-insensitive
  sub_type = lower(r[2]) -- sub_type is case-insensitive

  local iterator = ngx_re_gmatch(mime_type, parameter_pattern, "jo")
  local match = iterator and iterator()
  -- only extract first parameter, truncate others
  if match then
    params = {}
    local key = lower(match.param) -- the parameter name tokens are case-insensitive
    local value = match.value
    if key == "charset" then
      value = lower(value) -- the "charset" parameter value is defined as being case-insensitive in [RFC2046]
    end
    params[key] = value
  end

  return type, sub_type, params
end


local content_type_allowed
do
  local conf_cache = setmetatable({}, {
    __mode = "k",
    __index = function(self, plugin_config)
      -- create if not found
      local conf = {}
      conf.lru = assert(lrucache.new(500))
      conf.parsed_list = {}
      for _, content_type in ipairs(plugin_config.allowed_content_types or EMPTY) do
        local type, sub_type, params = parse_mime_type(content_type)
        table_insert(conf.parsed_list, {
          type = type,
          sub_type = sub_type,
          params = params,
        })
      end
      -- store for future use an return
      self[plugin_config] = conf
      return conf
    end
  })

  function content_type_allowed(plugin_config, content_type)
    if not content_type then
      return false
    end

    local conf = conf_cache[plugin_config]
    -- test our cache
    local allowed = conf.lru:get(content_type)
    if allowed ~= nil then
      return allowed
    end

    -- nothing in cache, try and parse
    allowed = false
    local type, sub_type, params = parse_mime_type(content_type)
    for _, parsed in ipairs(conf.parsed_list) do
      if (type == parsed.type or parsed.type == "*")
        and (sub_type == parsed.sub_type or parsed.sub_type == "*") then
        local params_match = true
        for key, value in pairs(parsed.params or EMPTY) do
          if value ~= (params or EMPTY)[key] then
            params_match = false
            break
          end
        end
        local n1 = params and 1 or 0 -- This works as we only allow one parameter
        local n2 = parsed.params and 1 or 0
        if params_match and n1 == n2 then
          allowed = true
          break
        end
      end
    end

    -- store in cache
    conf.lru:set(content_type, allowed)
    return allowed
  end
end


-- meta table for the sandbox, exposing lazily loaded values
-- todo use pdk
local template_environment
local __meta_environment = {
  __index = function(self, key)
    local lazy_loaders = {
      header = function(self)
        return req_get_headers() or EMPTY
      end,
      query = function(self)
        return req_get_uri_args() or EMPTY
      end,
      path = function(self)
        return (ngx.ctx.router_matches or EMPTY).uri_captures or EMPTY
      end,
    }
    local loader = lazy_loaders[key]
    if not loader then
      -- we don't have a loader, so just return nothing
      return
    end
    -- set the result on the table to not load again
    local value = loader()
    rawset(self, key, value)
    return value
  end,
  __new_index = function(self)
    error("This environment is read-only.")
  end,
}


template_environment = setmetatable({
  -- here we can optionally add functions to expose to the sandbox, eg:
  -- tostring = tostring,  -- for example
}, __meta_environment)


local function clear_environment()
  rawset(template_environment, "header", nil)
  rawset(template_environment, "query", nil)
  rawset(template_environment, "path", nil)
end


local validator_cache = setmetatable({}, {
  __mode = "k",
  __index = function(self, plugin_config)
      -- it was not found, so here we generate it
      local generator = require(validators[plugin_config.version]).generate
      local validator_func = assert(generator(plugin_config.body_schema))
      self[plugin_config] = validator_func
    return validator_func
  end
})


local validator_param_cache = setmetatable({}, {
  __mode = "k",
  __index = function(self, parameter)
    -- it was not found, so here we generate it
    local generator = require(validators.draft4).generate
    local validator_func = assert(generator(parameter.schema, {
      coercion = true,
    }))
    parameter.decoded_schema = assert(json_decode(parameter.schema))
    self[parameter] = validator_func
    return validator_func
  end
})


local function get_req_body_json()
  ngx_req_read_body()

  local body_data = ngx_req_get_body_data()
  if not body_data or #body_data == 0 then
    return {}
  end

  -- try to decode body data as json
  local body, err = json_decode(body_data)
  if err then
    return nil, "request body is not valid JSON"
  end

  return body
end


-- validates the 'required' property of a schema
local function validate_required(location, parameter)
  if location == "query" and parameter.style == "deepObject" then
    return true
  end

  local value = template_environment[location][parameter.name]
  if parameter.required and value == nil then
    return false, "required parameter missing"
  end

  parameter.value = value
  return true
end


local validate_data do
  local function validate_style_deepobject(location, parameter)

    local validator = validator_param_cache[parameter]

    local result, err =  deserialize(parameter.style, parameter.decoded_schema.type,
            parameter.explode, parameter.name, template_environment[location], location)
    if err == "not found" and not parameter.required then
      return true
    end

    if err or not result then
      return false, err
    end

    return validator(result)
  end

  local tables_allowed = {
    object = true,
    array = true,
  }

  validate_data = function(location, parameter)
    if location == "query" and parameter.style == "deepObject" then
      return validate_style_deepobject(location, parameter)
    end

    -- if param is not required and value is nil or serialization
    -- information not being set, return valid
    if not parameter.value or parameter.style == ngx_null  then
      return true
    end

    local validator = validator_param_cache[parameter]
    if type(parameter.value) ~= "table" or tables_allowed[parameter.decoded_schema.type] then
      -- if the value is a table, then we can only validate it for non-primitives
      local result, err =  deserialize(parameter.style, parameter.decoded_schema.type,
              parameter.explode, parameter.value, nil, parameter["in"])
      if err or not result then
        return false, err
      end

      local ok, err = validator(result)
      return ok, err, result
    end

    -- by now we have a primitive type (not array nor object) and the value is a table
    -- so we got duplicate headers or query values. We need to validate them individually.
    for _, value in ipairs(parameter.value) do
      local result, err =  deserialize(parameter.style, parameter.decoded_schema.type,
            parameter.explode, value, nil, parameter["in"])
      if err or not result then
        return false, err
      end

      local ok, err = validator(result)
      if not ok then
        return ok, err, result
      end
    end
    return true, nil, parameter.value
  end
end

local function validate_parameters(location, parameter)
  local ok, err, data = validate_required(location, parameter)
  if not ok then
    return false, err, data
  end

  ok, err, data = validate_data(location, parameter)
  if not ok then
    return false, err, data
  end

  return true
end


local RequestValidator = {
  PRIORITY = 999,
  VERSION = meta.core_version
}


function RequestValidator:access(conf)
  -- validate parameters
  clear_environment()
  for _, parameter in ipairs(conf.parameter_schema or EMPTY) do
    local ok, err, data = validate_parameters(parameter["in"], parameter)
    if not ok then
      if err and conf.verbose_response then
        return kong.response.exit(400, {
            message = fmt("%s '%s' validation failed, [error] %s",
                          parameter["in"], parameter.name, err),
            data = data,
        })
      end
      return kong.response.exit(400, { message = DENY_PARAM_MESSAGE })
    end
  end

  if conf.body_schema then
    local content_type = kong.request.get_header("content-type")
    if not content_type_allowed(conf, content_type) then
      if conf.verbose_response then
        return kong.response.exit(400, { message = DENY_BODY_MESSAGE_CT })
      end
      return kong.response.exit(400, { message = DENY_BODY_MESSAGE })
    end

    if not string_find(content_type, "application/json") then
      return
    end

    -- try to retrieve cached request body schema entity
    -- if it isn't in cache, it will be created
    local validator = validator_cache[conf]

    local body, err = get_req_body_json()
    if not body then
      return kong.response.exit(400, err)
    end

    -- try to validate body against schema
    local ok, err = validator(body)
    if not ok then
      if err and conf.verbose_response then
        return kong.response.exit(400, { message = err })
      end
      return kong.response.exit(400, { message = DENY_BODY_MESSAGE })
    end
  end

end

return RequestValidator
