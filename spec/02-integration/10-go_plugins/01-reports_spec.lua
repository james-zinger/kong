-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local constants = require "kong.constants"
local cjson = require "cjson"
local pl_file = require "pl.file"

for _, strategy in helpers.each_strategy() do
  local admin_client
  local dns_hostsfile
  local reports_server

  describe("#flaky anonymous reports for go plugins #" .. strategy, function()
    local reports_send_ping = function(port)
      ngx.sleep(0.01) -- hand over the CPU so other threads can do work (processing the sent data)
      local admin_client = helpers.admin_client()
      local res = admin_client:post("/reports/send-ping" .. (port and "?port=" .. port or ""))
      assert.response(res).has_status(200)
      admin_client:close()
    end


    lazy_setup(function()
      dns_hostsfile = assert(os.tmpname() .. ".hosts")
      local fd = assert(io.open(dns_hostsfile, "w"))
      assert(fd:write("127.0.0.1 " .. constants.REPORTS.ADDRESS))
      assert(fd:close())

      local bp = assert(helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, { "reports-api" }))

      local http_srv = assert(bp.services:insert {
        name = "mock-service",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      bp.routes:insert({ service = http_srv,
                         protocols = { "http" },
                         hosts = { "http-service.test" }})

      bp.plugins:insert({
        name = "reports-api",
        config = {}
      })

      local kong_prefix = helpers.test_conf.prefix

      assert(helpers.start_kong({
        nginx_conf = "spec/fixtures/custom_nginx.template",
        database = strategy,
        dns_hostsfile = dns_hostsfile,
        plugins = "bundled,reports-api,go-hello",
        pluginserver_names = "test",
        pluginserver_test_socket = kong_prefix .. "/go-hello.socket",
        pluginserver_test_query_cmd = "./spec/fixtures/go/go-hello -dump -kong-prefix " .. kong_prefix,
        pluginserver_test_start_cmd = "./spec/fixtures/go/go-hello -kong-prefix " .. kong_prefix,
        anonymous_reports = true,
      }))

      admin_client = helpers.admin_client()

      local res = admin_client:post("/plugins", {
        headers = {
          ["Content-Type"] = "application/json"
        },
        body = {
          name = "go-hello",
          config = {
            message = "Kong!"
          }
        }
      })
      assert.res_status(201, res)
    end)

    lazy_teardown(function()
      os.remove(dns_hostsfile)

      helpers.stop_kong()
    end)

    before_each(function()
      constants.REPORTS.STATS_TLS_PORT = constants.REPORTS.STATS_TLS_PORT + math.random(1, 50)
      reports_server = helpers.tcp_server(constants.REPORTS.STATS_TLS_PORT, {tls=true})
    end)

    it("logs number of enabled go plugins", function()
      reports_send_ping(constants.REPORTS.STATS_TLS_PORT)

      local _, reports_data = assert(reports_server:join())
      reports_data = cjson.encode(reports_data)

      assert.match("go_plugins_cnt=1", reports_data)
    end)

    it("logs number of requests triggering a go plugin", function()
      local proxy_client = assert(helpers.proxy_client())
      local res = proxy_client:get("/", {
        headers = { host  = "http-service.test" }
      })
      assert.res_status(200, res)

      reports_send_ping(constants.REPORTS.STATS_TLS_PORT)

      local _, reports_data = assert(reports_server:join())
      reports_data = cjson.encode(reports_data)

      assert.match("go_plugin_reqs=1", reports_data)
      assert.match("go_plugin_reqs=1", reports_data)
      proxy_client:close()
    end)

    it("runs fake 'response' phase", function()
      local proxy_client = assert(helpers.proxy_client())
      local res = proxy_client:get("/", {
        headers = { host  = "http-service.test" }
      })
      assert.res_status(200, res)
      assert.equal("got from server 'mock-upstream/1.0.0'", res.headers['x-hello-from-go-at-response'])
      proxy_client:close()
    end)

    describe("log phase has access to stuff", function()
      it("puts that stuff in the log", function()
        local proxy_client = assert(helpers.proxy_client())
        local res = proxy_client:get("/", {
          headers = { host  = "http-service.test" }
        })
        assert.res_status(200, res)
        proxy_client:close()

        local cfg = helpers.test_conf
        local logs = pl_file.read(cfg.prefix .. "/" .. cfg.proxy_error_log)

        for _, logpat in ipairs{
          "access_start: %d%d+\n",
          "shared_msg: Kong!\n",
          "serialized:%b{}\n",
        } do
          assert.match(logpat, logs)
        end
      end)
    end)

  end)
end
