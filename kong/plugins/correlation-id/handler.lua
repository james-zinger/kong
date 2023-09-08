-- Copyright (C) Kong Inc.
local uuid = require "kong.tools.utils".uuid
local kong_meta = require "kong.meta"
local request_id = require "kong.tracing.request_id"


local kong = kong


local worker_uuid
local worker_counter
local generators


do
  local worker_pid = ngx.worker.pid()
  local now = ngx.now
  local var = ngx.var
  local fmt = string.format

  generators = {
    ["uuid"] = function()
      return uuid()
    end,
    ["uuid#counter"] = function()
      worker_counter = worker_counter + 1
      return worker_uuid .. "#" .. worker_counter
    end,
    ["tracker"] = function()
      return fmt("%s-%s-%d-%s-%s-%0.3f",
        var.server_addr,
        var.server_port,
        worker_pid,
        var.connection, -- connection serial number
        var.connection_requests, -- current number of requests made through a connection
        now() -- the current time stamp from the nginx cached time.
      )
    end,
  }
end


local CorrelationIdHandler = {}


CorrelationIdHandler.PRIORITY = 1
CorrelationIdHandler.VERSION = kong_meta.version


function CorrelationIdHandler:init_worker()
  worker_uuid = uuid()
  worker_counter = 0
end


function CorrelationIdHandler:access(conf)
  -- Set header for upstream
  local correlation_id = kong.request.get_header(conf.header_name)
  if not correlation_id or correlation_id == "" then
    -- Generate the header value
    correlation_id = generators[conf.generator]()
    if correlation_id then
      kong.service.request.set_header(conf.header_name, correlation_id)
    end
  end

  if correlation_id then
    local _, err = request_id.set(correlation_id, request_id.TYPES.CORR)
    if err then
      kong.log.notice(err)
    end
  end

  if conf.echo_downstream then
    -- For later use, to echo it back downstream
    kong.ctx.plugin.correlation_id = correlation_id
  end
end


function CorrelationIdHandler:header_filter(conf)
  if not conf.echo_downstream then
    return
  end

  local correlation_id = kong.ctx.plugin.correlation_id or
                         kong.request.get_header(conf.header_name)

  if not correlation_id or correlation_id == "" then
    correlation_id = generators[conf.generator]()
  end

  kong.response.set_header(conf.header_name, correlation_id)
end


return CorrelationIdHandler
