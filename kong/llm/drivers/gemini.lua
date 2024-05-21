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
--

-- globals
local DRIVER_NAME = "gemini"
--

local _OPENAI_ROLE_MAPPING = {
  ["system"] = "system",
  ["user"] = "user",
  ["assistant"] = "model",
}

local function to_gemini_generation_config(request_table)
  return {
    ["maxOutputTokens"] = request_table.max_tokens,
    ["stopSequences"] = request_table.stop,
    ["temperature"] = request_table.temperature,
    ["topK"] = request_table.top_k,
    ["topP"] = request_table.top_p,
  }
end

local function to_gemini_chat_openai(request_table, model_info, route_type)
  if request_table then  -- try-catch type mechanism
    local new_r = {}

    if request_table.messages and #request_table.messages > 0 then
      local system_prompt

      for i, v in ipairs(request_table.messages) do

        -- for 'system', we just concat them all into one Gemini instruction
        if v.role and v.role == "system" then
          system_prompt = system_prompt or buffer.new()
          system_prompt:put(v.content or "")
        else
          -- for any other role, just construct the chat history as 'parts.text' type
          new_r.contents = new_r.contents or {}
          table_insert(new_r.contents, {
            role = _OPENAI_ROLE_MAPPING[v.role or "user"],  -- default to 'user'
            parts = {
              {
                text = v.content or ""
              },
            },
          })
        end
      end

      -- This was only added in Gemini 1.5
      if system_prompt and model_info.name:sub(1, 10) == "gemini-1.0" then
        return nil, nil, "system prompts aren't supported on gemini-1.0 models"

      elseif system_prompt then
        new_r.systemInstruction = {
          parts = {
            {
              text = system_prompt:get(),
            },
          },
        }
      end
    end

    new_r.generationConfig = to_gemini_generation_config(request_table)

    kong.log.debug(cjson.encode(new_r))

    return new_r, "application/json", nil
  end

  local new_r = {}

  if request_table.messages and #request_table.messages > 0 then
    local system_prompt

    for i, v in ipairs(request_table.messages) do

      -- for 'system', we just concat them all into one Gemini instruction
      if v.role and v.role == "system" then
        system_prompt = system_prompt or buffer.new()
        system_prompt:put(v.content or "")
      else
        -- for any other role, just construct the chat history as 'parts.text' type
        new_r.contents = new_r.contents or {}
        table_insert(new_r.contents, {
          role = _OPENAI_ROLE_MAPPING[v.role or "user"],  -- default to 'user'
          parts = {
            {
              text = v.content or ""
            },
          },
        })
      end
    end

    -- only works for gemini 1.5+
    -- if system_prompt then
    --   if string_sub(model_info.name, 1, 10) == "gemini-1.0" then
    --     return nil, nil, "system prompts only work with gemini models 1.5 or later"
    --   end

    --   new_r.systemInstruction = {
    --     parts = {
    --       {
    --         text = system_prompt:get(),
    --       },
    --     },
    --   }
    -- end
    --
  end

  kong.log.debug(cjson.encode(new_r))

  new_r.generationConfig = to_gemini_generation_config(request_table)

  return new_r, "application/json", nil
end

local function from_gemini_chat_openai(response, model_info, route_type)
  local response, err = cjson.decode(response)

  if err then
    local err_client = "failed to decode response from Gemini"
    ngx.log(ngx.ERR, fmt("%s: %s", err_client, err))
    return nil, err_client
  end

  -- messages/choices table is only 1 size, so don't need to static allocate
  local messages = {}
  messages.choices = {}

  if response.candidates
        and #response.candidates > 0
        and response.candidates[1].content
        and response.candidates[1].content.parts
        and #response.candidates[1].content.parts > 0
        and response.candidates[1].content.parts[1].text then

    messages.choices[1] = {
      index = 0,
      message = {
        role = "assistant",
        content = response.candidates[1].content.parts[1].text,
      },
      finish_reason = string_lower(response.candidates[1].finishReason),
    }
    messages.object = "chat.completion"
    messages.model = model_info.name

  else -- probably a server fault or other unexpected response
    local err = "no generation candidates received from Gemini, or max_tokens too short"
    ngx.log(ngx.ERR, err)
    return nil, err
  end

  return cjson.encode(messages)
end

local function to_gemini_chat_gemini(request_table, model_info, route_type)
  return nil, nil, "gemini to gemini not yet implemented"
end

local function from_gemini_chat_gemini(request_table, model_info, route_type)
  return nil, nil, "gemini to gemini not yet implemented"
end

local transformers_to = {
  ["llm/v1/chat"] = to_gemini_chat_openai,
  ["gemini/v1/chat"] = to_gemini_chat_gemini,
}

local transformers_from = {
  ["llm/v1/chat"] = from_gemini_chat_openai,
  ["gemini/v1/chat"] = from_gemini_chat_gemini,
}

function _M.from_format(response_string, model_info, route_type)
  ngx.log(ngx.DEBUG, "converting from ", model_info.provider, "://", route_type, " type to kong")

  -- MUST return a string, to set as the response body
  if not transformers_from[route_type] then
    return nil, fmt("no transformer available from format %s://%s", model_info.provider, route_type)
  end
  
  local ok, response_string, err = pcall(transformers_from[route_type], response_string, model_info, route_type)
  if not ok or err then
    return nil, fmt("transformation failed from type %s://%s: %s",
                    model_info.provider,
                    route_type,
                    err or "unexpected_error"
                  )
  end

  return response_string, nil
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
  kong.service.request.set_header("Accept-Encoding", "gzip, identity") -- tell server not to send brotli

  return true, nil
end

-- returns err or nil
function _M.configure_request(conf)
  local parsed_url
  local operation = kong.ctx.shared.ai_proxy_streaming_mode and "streamGenerateContent"
                                                             or "generateContent"
  local f_url = conf.model.options and conf.model.options.upstream_url

  if not f_url then  -- upstream_url override is not set
    -- check if this is "public" or "vertex" gemini deployment
    if conf.model.options
        and conf.model.options.gemini
        and conf.model.options.gemini.api_endpoint
        and conf.model.options.gemini.project_id
        and conf.model.options.gemini.location_id
    then
      -- vertex mode
      f_url = fmt(ai_shared.upstream_url_format["gemini_vertex"],
                  conf.model.options.gemini.api_endpoint) ..
              fmt(ai_shared.operation_map["gemini_vertex"][conf.route_type].path,
                  conf.model.options.gemini.project_id,
                  conf.model.options.gemini.location_id,
                  conf.model.name,
                  operation)
    else
      -- public mode
      f_url = ai_shared.upstream_url_format["gemini"] ..
              fmt(ai_shared.operation_map["gemini"][conf.route_type].path,
                  conf.model.name,
                  operation)
    end
  end

  parsed_url = socket_url.parse(f_url)

  kong.log.inspect(parsed_url)

  if conf.model.options and conf.model.options.upstream_path then
    -- upstream path override is set (or templated from request params)
    parsed_url.path = conf.model.options.upstream_path
  end

  -- if the path is read from a URL capture, ensure that it is valid
  parsed_url.path = string_gsub(parsed_url.path, "^/*", "/")

  kong.service.request.set_path(parsed_url.path)
  kong.service.request.set_scheme(parsed_url.scheme)
  kong.service.set_target(parsed_url.host, (tonumber(parsed_url.port) or 443))

  local auth_header_name = conf.auth and conf.auth.header_name
  local auth_header_value = conf.auth and conf.auth.header_value
  local auth_param_name = conf.auth and conf.auth.param_name
  local auth_param_value = conf.auth and conf.auth.param_value
  local auth_param_location = conf.auth and conf.auth.param_location

  if auth_header_name and auth_header_value then
    kong.service.request.set_header(auth_header_name, auth_header_value)
  end

  if auth_param_name and auth_param_value and auth_param_location == "query" then
    local query_table = kong.request.get_query()
    query_table[auth_param_name] = auth_param_value
    kong.service.request.set_query(query_table)
  end

  -- ---- DEBUG REMOVE THIS
  -- local auth = require("resty.gcp.request.credentials.accesstoken"):new(conf.auth.gcp_service_account_json)
  -- kong.service.request.set_header("Authorization", "Bearer " .. auth.token)
  -- ----

  -- if auth_param_location is "form", it will have already been set in a global pre-request hook
  return true, nil
end

return _M