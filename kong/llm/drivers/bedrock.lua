local _M = {}

-- imports
local cjson = require("cjson.safe")
local fmt = string.format
local ai_shared = require("kong.llm.drivers.shared")
local socket_url = require("socket.url")
local string_gsub = string.gsub
local buffer = require("string.buffer")
local table_insert = table.insert
local string_lower = string.lower
local string_sub = string.sub
local signer = require("resty.aws.request.sign")
--

-- globals
local DRIVER_NAME = "bedrock"
--

local _OPENAI_ROLE_MAPPING = {
  ["system"] = "assistant",
  ["user"] = "user",
  ["assistant"] = "assistant",
}

local function to_bedrock_generation_config(request_table)
  return {
    ["maxTokens"] = request_table.max_tokens,
    ["stopSequences"] = request_table.stop,
    ["temperature"] = request_table.temperature,
    ["topP"] = request_table.top_p,
  }
end

local function handle_stream_event(event_t, model_info, route_type)
  local metadata

  return "yes", nil, nil
end

local function to_bedrock_chat_openai(request_table, model_info, route_type)
  if not request_table then  -- try-catch type mechanism
    local err = "empty request table received for transformation"
    ngx.log(ngx.ERR, err)
    return nil, nil, err
  end

  local new_r = {}

  -- anthropic models support variable versions, just like self-hosted
  new_r.anthropic_version = model_info.options and model_info.options.anthropic_version
                         or "bedrock-2023-05-31"

  if request_table.messages and #request_table.messages > 0 then
    local system_prompt

    for i, v in ipairs(request_table.messages) do
      -- for 'system', we just concat them all into one Gemini instruction
      if v.role and v.role == "system" then
        system_prompt = system_prompt or buffer.new()
        system_prompt:put(v.content or "")

      else
        -- for any other role, just construct the chat history as 'parts.text' type
        new_r.messages = new_r.messages or {}
        table_insert(new_r.messages, {
          role = _OPENAI_ROLE_MAPPING[v.role or "user"],  -- default to 'user'
          content = {
            {
              text = v.content or ""
            },
          },
        })
      end
    end

    -- only works for 
    if system_prompt then
      new_r.system = system_prompt:get()
    end
  end

  new_r.inferenceConfig = to_bedrock_generation_config(request_table)

  kong.log.debug(new_r.inferenceConfig.maxTokens)

  return new_r, "application/json", nil
end

local function from_bedrock_chat_openai(response, model_info, route_type)
  local response, err = cjson.decode(response)

  if err then
    local err_client = "failed to decode response from Bedrock"
    ngx.log(ngx.ERR, fmt("%s: %s", err_client, err))
    return nil, err_client
  end

  -- messages/choices table is only 1 size, so don't need to static allocate
  local client_response = {}
  client_response.choices = {}

  if response.output
        and response.output.message
        and response.output.message.content
        and #response.output.message.content > 0
        and response.output.message.content[1].text then

          client_response.choices[1] = {
      index = 0,
      message = {
        role = "assistant",
        content = response.output.message.content[1].text,
      },
      finish_reason = string_lower(response.stopReason),
    }
    client_response.object = "chat.completion"
    client_response.model = model_info.name

  else -- probably a server fault or other unexpected response
    local err = "no generation candidates received from Bedrock, or max_tokens too short"
    ngx.log(ngx.ERR, err)
    return nil, err
  end

  -- process analytics
  if response.usage then
    client_response.usage = {
      prompt_tokens = response.usage.inputTokens,
      completion_tokens = response.usage.outputTokens,
      total_tokens = response.usage.totalTokens,
    }
  end

  return cjson.encode(client_response)
end

local transformers_to = {
  ["llm/v1/chat"] = to_bedrock_chat_openai,
}

local transformers_from = {
  ["llm/v1/chat"] = from_bedrock_chat_openai,
  ["stream/llm/v1/chat"] = handle_stream_event,
}

function _M.from_format(response_string, model_info, route_type)
  ngx.log(ngx.DEBUG, "converting from ", model_info.provider, "://", route_type, " type to kong")

  -- MUST return a string, to set as the response body
  if not transformers_from[route_type] then
    return nil, fmt("no transformer available from format %s://%s", model_info.provider, route_type)
  end
  
  local ok, response_string, err, metadata = pcall(transformers_from[route_type], response_string, model_info, route_type)
  if not ok or err then
    return nil, fmt("transformation failed from type %s://%s: %s",
                    model_info.provider,
                    route_type,
                    err or "unexpected_error"
                  )
  end

  return response_string, nil, metadata
end

function _M.to_format(request_table, model_info, route_type)
  ngx.log(ngx.DEBUG, "converting from kong type to ", model_info.provider, "/", route_type)

  if route_type == "preserve" then
    -- do nothing
    return request_table, nil, nil
  end

  if not transformers_to[route_type] then
    return nil, nil, fmt("no transformer for %s://%s", model_info.provider, route_type)
  end

  request_table = ai_shared.merge_config_defaults(request_table, model_info.options, model_info.route_type)

  local ok, response_object, content_type, err = pcall(
    transformers_to[route_type],
    request_table,
    model_info
  )
  if err or (not ok) then
    return nil, nil, fmt("error transforming to %s://%s: %s", model_info.provider, route_type, err)
  end

  return response_object, content_type, nil
end

function _M.subrequest(body, conf, http_opts, return_res_table)
  -- use shared/standard subrequest routine
  local body_string, err

  if type(body) == "table" then
    body_string, err = cjson.encode(body)
    if err then
      return nil, nil, "failed to parse body to json: " .. err
    end
  elseif type(body) == "string" then
    body_string = body
  else
    return nil, nil, "body must be table or string"
  end

  -- may be overridden
  local url = (conf.model.options and conf.model.options.upstream_url)
    or fmt(
    "%s%s",
    ai_shared.upstream_url_format[DRIVER_NAME],
    ai_shared.operation_map[DRIVER_NAME][conf.route_type].path
  )

  local method = ai_shared.operation_map[DRIVER_NAME][conf.route_type].method

  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
  }

  if conf.auth and conf.auth.header_name then
    headers[conf.auth.header_name] = conf.auth.header_value
  end

  local res, err, httpc = ai_shared.http_request(url, body_string, method, headers, http_opts, return_res_table)
  if err then
    return nil, nil, "request to ai service failed: " .. err
  end

  if return_res_table then
    return res, res.status, nil, httpc
  else
    -- At this point, the entire request / response is complete and the connection
    -- will be closed or back on the connection pool.
    local status = res.status
    local body   = res.body

    if status > 299 then
      return body, res.status, "status code " .. status
    end

    return body, res.status, nil
  end
end

function _M.header_filter_hooks(body)
  -- nothing to parse in header_filter phase
end

function _M.post_request(conf)
  if ai_shared.clear_response_headers[DRIVER_NAME] then
    for i, v in ipairs(ai_shared.clear_response_headers[DRIVER_NAME]) do
      kong.response.clear_header(v)
    end
  end
end

function _M.pre_request(conf, body)
  -- disable gzip for bedrock because it breaks streaming
  kong.service.request.set_header("Accept-Encoding", "gzip, identity")

  return true, nil
end

-- returns err or nil
function _M.configure_request(conf, aws_sdk)
  local operation = kong.ctx.shared.ai_proxy_streaming_mode and "converse-stream"
                                                             or "converse"

  local f_url = conf.model.options and conf.model.options.upstream_url

  if not f_url then  -- upstream_url override is not set
    local uri = fmt(ai_shared.upstream_url_format[DRIVER_NAME], aws_sdk.config.region)
    local path = fmt(
      ai_shared.operation_map[DRIVER_NAME][conf.route_type].path,
      conf.model.name,
      operation)

    f_url = fmt("%s%s", uri, path)
  end

  local parsed_url = socket_url.parse(f_url)

  if conf.model.options and conf.model.options.upstream_path then
    -- upstream path override is set (or templated from request params)
    parsed_url.path = conf.model.options.upstream_path
  end

  -- if the path is read from a URL capture, ensure that it is valid
  parsed_url.path = string_gsub(parsed_url.path, "^/*", "/")

  kong.service.request.set_path(parsed_url.path)
  kong.service.request.set_scheme(parsed_url.scheme)
  kong.service.set_target(parsed_url.host, (tonumber(parsed_url.port) or 443))

  -- do the IAM auth and signature headers
  aws_sdk.config.signatureVersion = "v4"
  aws_sdk.config.endpointPrefix = "bedrock"

  local r = {
    headers = {},
    method = ai_shared.operation_map[DRIVER_NAME][conf.route_type].method,
    path = parsed_url.path,
    host = parsed_url.host,
    port = tonumber(parsed_url.port) or 443,
    body = kong.request.get_raw_body()
  }

  local signature = signer(aws_sdk.config, r)

  kong.service.request.set_header("Authorization", signature.headers["Authorization"])
  kong.service.request.set_header("X-Amz-Security-Token", signature.headers["X-Amz-Security-Token"] or "")
  kong.service.request.set_header("X-Amz-Date", signature.headers["X-Amz-Date"] or "")

  return true
end

return _M