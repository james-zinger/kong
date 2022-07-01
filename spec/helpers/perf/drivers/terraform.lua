-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local perf = require("spec.helpers.perf")
local pl_path = require("pl.path")
local cjson = require("cjson")
local tools = require("kong.tools.utils")
math.randomseed(os.time())

local _M = {}
local mt = {__index = _M}

local UPSTREAM_PORT = 8088
local KONG_ADMIN_PORT
local PG_PASSWORD = tools.random_string()
local KONG_ERROR_LOG_PATH = "/tmp/error.log"
-- threshold for load_avg / nproc, not based on specific research,
-- just a arbitrary number to ensure test env is normalized
local LOAD_NORMALIZED_THRESHOLD = 0.2

function _M.new(opts)
  local provider = opts and opts.provider or "equinix-metal"
  local work_dir = "./spec/fixtures/perf/terraform/" .. provider
  if not pl_path.exists(work_dir) then
    error("Hosting provider " .. provider .. " unsupported: expect " .. work_dir .. " to exists", 2)
  end

  local tfvars = ""
  if opts and opts.tfvars then
    for k, v in pairs(opts.tfvars) do
      tfvars = string.format("%s -var '%s=%s' ", tfvars, k, v)
    end
  end

  return setmetatable({
    opts = opts,
    log = perf.new_logger("[terraform]"),
    ssh_log = perf.new_logger("[terraform][ssh]"),
    provider = provider,
    work_dir = work_dir,
    tfvars = tfvars,
    kong_ip = nil,
    kong_internal_ip = nil,
    worker_ip = nil,
    worker_internal_ip = nil,
    systemtap_sanity_checked = false,
    systemtap_dest_path = nil,
    daily_image_desc = nil,
  }, mt)
end

local function ssh_execute_wrap(self, ip, cmd)
  -- to quote a ', one need to finish the current ', quote the ' then start a new '
  cmd = string.gsub(cmd, "'", "'\\''")
  return "ssh " ..
          "-o IdentityFile=" .. self.work_dir .. "/id_rsa " .. -- TODO: no hardcode
          "-o TCPKeepAlive=yes -o ServerAliveInterval=300 " ..
          -- turn on connection multiplexing
          "-o ControlPath=" .. self.work_dir .. "/cm-%r@%h:%p " ..
          "-o ControlMaster=auto -o ControlPersist=10m " ..
          -- no interactive prompt for saving hostkey
          "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no " ..
          "root@" .. ip .. " '" .. cmd .. "'"
end

-- if remote_ip is set, run remotely; else run on host machine
local function execute_batch(self, remote_ip, cmds, continue_on_error)
  for _, cmd in ipairs(cmds) do
    if remote_ip then
      cmd = ssh_execute_wrap(self, remote_ip, cmd)
    end
    local _, err = perf.execute(cmd, {
      logger = (remote_ip and self.ssh_log or self.log).log_exec
    })
    if err then
      if not continue_on_error then
        return false, "failed in \"" .. cmd .. "\": ".. (err or "nil")
      end
      self.log.warn("execute ", cmd, " has error: ", (err or "nil"))
    end
  end
  return true
end

function _M:setup(opts)
  local bin, _ = perf.execute("which terraform")
  if not bin then
    return nil, "terraform binary not found"
  end

  local ok, err
  -- terraform apply
  self.log.info("Running terraform to provision instances...")

  ok, err = execute_batch(self, nil, {
    "terraform version",
    "cd " .. self.work_dir .. " && terraform init",
    "cd " .. self.work_dir .. " && terraform apply -auto-approve " .. self.tfvars,
  })
  if not ok then
    return false, err
  end

  -- grab outputs
  local res, err = perf.execute("cd " .. self.work_dir .. " && terraform show -json")
  if err then
    return false, "terraform show: " .. err
  end
  res = cjson.decode(res)

  self.kong_ip = res.values.outputs["kong-ip"].value
  self.kong_internal_ip = res.values.outputs["kong-internal-ip"].value
  self.worker_ip = res.values.outputs["worker-ip"].value
  self.worker_internal_ip = res.values.outputs["worker-internal-ip"].value

  -- install psql docker on kong
  ok, err = execute_batch(self, self.kong_ip, {
    "apt-get update", "apt-get install -y --force-yes docker.io",
    "docker rm -f kong-database || true", -- if exist remove it
    "docker run -d -p5432:5432 "..
            "-e POSTGRES_PASSWORD=" .. PG_PASSWORD .. " " ..
            "-e POSTGRES_DB=kong_tests " ..
            "-e POSTGRES_USER=kong --name=kong-database postgres:13 -c max_connections=5000",
  })
  if not ok then
    return ok, err
  end

  -- wait
  local cmd = ssh_execute_wrap(self, self.kong_ip,
                              "docker logs -f kong-database")
  if not perf.wait_output(cmd, "is ready to accept connections", 5) then
    return false, "timeout waiting psql to start (5s)"
  end
  -- slightly wait a bit: why?
  ngx.sleep(1)

  perf.setenv("KONG_PG_HOST", self.kong_ip)
  perf.setenv("KONG_PG_PASSWORD", PG_PASSWORD)
  -- self.log.debug("(In a low voice) pg_password is " .. PG_PASSWORD)

  self.log.info("Infra is up! However, executing psql remotely may take a while...")
  for i=1, 3 do
    perf.clear_loaded_package()

    local pok, pret = pcall(require, "spec.helpers")
    if pok then
      pret.admin_client = function(timeout)
        return pret.http_client(self.kong_ip, KONG_ADMIN_PORT, timeout or 60000)
      end
      perf.unsetenv("KONG_PG_HOST")
      perf.unsetenv("KONG_PG_PASSWORD")

      return pret
    end
    self.log.warn("unable to load spec.helpers: " .. (pret or "nil") .. ", try " .. i)
    ngx.sleep(1)
  end
  error("Unable to load spec.helpers")
end

function _M:teardown(full)
  if full then
    -- terraform destroy
    self.log.info("Running terraform to destroy instances...")

    local ok, err = execute_batch(self, nil, {
      "terraform version",
      "cd " .. self.work_dir .. " && terraform init",
      "cd " .. self.work_dir .. " && terraform destroy -auto-approve " .. self.tfvars,
    })
    if not ok then
      return false, err
    end
  end

  perf.git_restore()

  -- otherwise do nothing
  return true
end

function _M:start_worker(conf, port_count)
  conf = conf or ""
  local listeners = {}
  for i=1,port_count do
    listeners[i] = ("listen %d reuseport;"):format(UPSTREAM_PORT+i-1)
  end
  listeners = table.concat(listeners, "\n")

  conf = ngx.encode_base64(([[
  worker_processes auto;
  worker_cpu_affinity auto;
  error_log /var/log/nginx/error.log;
  pid /run/nginx.pid;
  worker_rlimit_nofile 20480;

  events {
     accept_mutex off;
     worker_connections 10620;
  }

  http {
     access_log off;
     server_tokens off;
     keepalive_requests 10000;
     tcp_nodelay on;

     server {
         %s
         location =/health {
            return 200;
         }
         location / {
             return 200 " performancetestperformancetestperformancetestperformancetestperformancetest";
         }
         %s
     }
  }]]):format(listeners, conf)):gsub("\n", "")

  local ok, err = execute_batch(self, self.worker_ip, {
    "sudo id",
    "echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor",
    "sudo apt-get update", "sudo apt-get install -y --force-yes nginx",
    -- ubuntu where's wrk in apt?
    "wget -nv http://mirrors.kernel.org/ubuntu/pool/universe/w/wrk/wrk_4.1.0-3_amd64.deb -O wrk.deb",
    "dpkg -l wrk || (sudo dpkg -i wrk.deb || sudo apt-get -f -y install)",
    "echo " .. conf .. " | sudo base64 -d > /etc/nginx/nginx.conf",
    "sudo nginx -t",
    "sudo systemctl restart nginx",
  })
  if not ok then
    return nil, err
  end

  local uris = {}
  for i=1,port_count do
    uris[i] = "http://" .. self.worker_internal_ip .. ":" .. UPSTREAM_PORT+i-1
  end
  return uris
end

function _M:start_kong(version, kong_conf, driver_conf)
  kong_conf = kong_conf or {}
  kong_conf["pg_password"] = PG_PASSWORD
  kong_conf["pg_database"] = "kong_tests"

  kong_conf['proxy_access_log'] = "/dev/null"
  kong_conf['proxy_error_log'] = KONG_ERROR_LOG_PATH
  kong_conf['admin_error_log'] = KONG_ERROR_LOG_PATH

  -- we set ip_local_port_range='10240 65535' make sure the random
  -- port doesn't fall into that range
  KONG_ADMIN_PORT = math.floor(math.random()*9000+1024)
  kong_conf['admin_listen'] = "0.0.0.0:" .. KONG_ADMIN_PORT
  kong_conf['anonymous_reports'] = "off"
  if not kong_conf['vitals'] then
    kong_conf['vitals'] = "off"
  end

  local kong_license_blob = ""
  if kong_conf['license_data'] then
    kong_license_blob = kong_conf['license_data']
    kong_conf['license_data'] = nil
  end

  local kong_conf_blob = ""
  for k, v in pairs(kong_conf) do
    kong_conf_blob = string.format("%s\n%s=%s\n", kong_conf_blob, k, v)
  end
  kong_conf_blob = ngx.encode_base64(kong_conf_blob):gsub("\n", "")

  local use_git

  if version:startswith("git:") then
    perf.git_checkout(version:sub(#("git:")+1))
    use_git = true

    version = perf.get_kong_version()
    self.log.debug("current git hash resolves to Kong version ", version)
  end

  local download_path
  if version:sub(1, 1) == "2" then
    if version:match("%d+%.%d+%.%d+%.%d+") then -- EE
      download_path = "https://download.konghq.com/gateway-2.x-ubuntu-focal/pool/all/k/kong-enterprise-edition/kong-enterprise-edition_" ..
                      version .. "_all.deb"
    elseif version:match("rc") or version:match("beta") then
      download_path = "https://download-stage.konghq.com/gateway-2.x-ubuntu-focal/pool/all/k/kong/kong_" ..
                      version .. "_amd64.deb"
    else
      download_path = "https://download.konghq.com/gateway-2.x-ubuntu-focal/pool/all/k/kong/kong_" ..
                      version .. "_amd64.deb"
    end
  else
    error("Unknown download location for Kong version " .. version)
  end

  local docker_extract_cmds
  self.daily_image_desc = nil
  -- daily image are only used when testing with git
  -- testing upon release artifact won't apply daily image files
  local daily_image = "kong/kong-gateway-internal:master-nightly-ubuntu20.04"
  if self.opts.use_daily_image and use_git then
    docker_extract_cmds = {
      "docker login -u " .. (os.getenv("DOCKER_USERNAME") or "x") ..
                    " -p " .. (os.getenv("DOCKER_PASSWORD") or "x"),
      "docker rm -f daily || true",
      "docker rmi -f " .. daily_image,
      "docker pull " .. daily_image,
      "docker create --name daily " .. daily_image,
      "sudo rm -rf /tmp/lua && sudo docker cp daily:/usr/local/share/lua/5.1/. /tmp/lua",
      -- don't overwrite kong source code, use them from current git repo instead
      "sudo rm -rf /tmp/lua/kong && sudo cp -r /tmp/lua/. /usr/local/share/lua/5.1/",
    }

    for _, dir in ipairs({"/usr/local/openresty",
                          "/usr/local/kong/include", "/usr/local/kong/lib"}) do
      -- notice the /. it makes sure the content not the directory itself is copied
      table.insert(docker_extract_cmds, "sudo docker cp daily:" .. dir .."/. " .. dir)
    end

    table.insert(docker_extract_cmds, "rm -rf /tmp/lua && sudo docker cp daily:/usr/local/share/lua/5.1/. /tmp/lua")
    table.insert(docker_extract_cmds, "sudo rm -rf /tmp/lua/kong && sudo cp -r /tmp/lua/. /usr/local/share/lua/5.1/")
    table.insert(docker_extract_cmds, "sudo kong check")
  end

  local ok, err = execute_batch(self, self.kong_ip, {
    "echo > " .. KONG_ERROR_LOG_PATH,
    "sudo id",
    -- set cpu scheduler to performance, it should lock cpufreq to static freq
    "echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor",
    -- increase outgoing port range to avoid 99: Cannot assign requested address
    "sudo sysctl net.ipv4.ip_local_port_range='10240 65535'",
    -- stop and remove kong if installed
    "dpkg -l kong && (sudo kong stop; sudo dpkg -r kong) || true",
    -- stop and remove kong-ee if installed
    "dpkg -l kong-enterprise-edition && (sudo kong stop; sudo dpkg -r kong-enterprise-edition) || true",
    -- have to do the pkill sometimes, because kong stop allow the process to linger for a while
    "sudo pkill -F /usr/local/kong/pids/nginx.pid || true",
    -- remove all lua files, not only those installed by package
    "sudo rm -rf /usr/local/share/lua/5.1/kong",
    "wget -nv " .. download_path .. " -O kong-" .. version .. ".deb",
    "sudo dpkg -i kong-" .. version .. ".deb || sudo apt-get -f -y install",
    "echo " .. kong_conf_blob .. " | sudo base64 -d > /etc/kong/kong.conf",
    "echo " .. kong_license_blob .. " | sudo base64 -d > /etc/kong/license.json",
    "sudo kong check",
  })
  if not ok then
    return false, err
  end

  if docker_extract_cmds then
    local ok, err = execute_batch(self, self.kong_ip, docker_extract_cmds)
    if not ok then
      return false, "error extracting docker daily image:" .. err
    end

    local manifest, err = perf.execute(ssh_execute_wrap(self, self.kong_ip, "docker inspect " .. daily_image))
    if err then
      return nil, "failed to inspect daily image: " .. err
    end
    local labels, err = perf.parse_docker_image_labels(manifest)
    if not labels then
      return nil, "failed to use parse daily image manifest: " .. err
    end

    self.log.debug("daily image " .. labels.version .." was pushed at ", labels.created)
    self.daily_image_desc = labels.version .. ", " .. labels.created
  end

  local ok, err = execute_batch(self, nil, {
    -- upload
    use_git and ("tar zc kong | " .. ssh_execute_wrap(self, self.kong_ip,
      "sudo tar zx -C /usr/local/share/lua/5.1; find /usr/local/openresty/site/lualib/kong/ -name '*.ljbc' -delete; true"))
      or "echo use stock files",
    use_git and (ssh_execute_wrap(self, self.kong_ip,
      "sudo cp -r /usr/local/share/lua/5.1/kong/include/. /usr/local/kong/include/"))
      or "echo use stock files",
    use_git and ("tar zc plugins-ee/*/kong/plugins/* --transform='s,plugins-ee/[^/]*/kong,kong,' | " ..
      ssh_execute_wrap(self, self.kong_ip, "sudo tar zx -C /usr/local/share/lua/5.1"))
      or "echo use stock files",
    -- new migrations
    ssh_execute_wrap(self, self.kong_ip,
      "kong migrations up -y && kong migrations finish -y"),
    -- start kong
    ssh_execute_wrap(self, self.kong_ip,
      "ulimit -n 655360; kong start || kong restart"),
  })
  if not ok then
    return false, err
  end

  return true
end

function _M:stop_kong()
  local load = perf.execute(ssh_execute_wrap(self, self.kong_ip,
              "cat /proc/loadavg")):match("[%d%.]+")
  self.log.debug("Kong node end 1m loadavg is ", load)

  return perf.execute(ssh_execute_wrap(self, self.kong_ip, "kong stop"),
                                { logger = self.ssh_log.log_exec })
end

function _M:get_start_load_cmd(stub, script, uri)
  if not uri then
    uri = string.format("http://%s:8000", self.kong_internal_ip)
  end

  local script_path
  if script then
    script_path = string.format("/tmp/wrk-%s.lua", tools.random_string())
    local out, err = perf.execute(
      ssh_execute_wrap(self, self.worker_ip, "tee " .. script_path),
      {
        stdin = script,
      })
    if err then
      return false, "failed to write script in remote machine: " .. (out or err)
    end
  end

  script_path = script_path and ("-s " .. script_path) or ""

  local nproc = tonumber(perf.execute(ssh_execute_wrap(self, self.kong_ip, "nproc")))
  local load, load_normalized
  while true do
    load = perf.execute(ssh_execute_wrap(self, self.kong_ip,
              "cat /proc/loadavg")):match("[%d%.]+")
    load_normalized = tonumber(load) / nproc
    if load_normalized < LOAD_NORMALIZED_THRESHOLD then
      break
    end
    self.log.info("waiting for Kong node 1m loadavg to drop under ",
                  nproc * LOAD_NORMALIZED_THRESHOLD)
    ngx.sleep(15)
  end
  self.log.debug("Kong node start 1m loadavg is ", load)

  return ssh_execute_wrap(self, self.worker_ip,
            stub:format(script_path, uri))
end

function _M:get_admin_uri(kong_id)
  return string.format("http://%s:%s", self.kong_internal_ip, KONG_ADMIN_PORT)
end

local function check_systemtap_sanity(self)
  local _, err = perf.execute(ssh_execute_wrap(self, self.kong_ip, "which stap"))
  if err then
    local ok, err = execute_batch(self, self.kong_ip, {
      "apt-get install g++ libelf-dev libdw-dev libssl-dev libsqlite3-dev libnss3-dev pkg-config python3 make -y --force-yes",
      "wget https://sourceware.org/systemtap/ftp/releases/systemtap-4.6.tar.gz -O systemtap.tar.gz",
      "tar xf systemtap.tar.gz",
      "cd systemtap-*/ && " ..
        "./configure --enable-sqlite --enable-bpf --enable-nls --enable-nss --enable-avahi && " ..
        "make PREFIX=/usr -j$(nproc) && "..
        "make install"
    })
    if not ok then
      return false, "failed to build systemtap: " .. err
    end
  end

  local ok, err = execute_batch(self, self.kong_ip, {
    "apt-get install gcc linux-headers-$(uname -r) -y --force-yes",
    "which stap",
    "stat /tmp/stapxx || git clone https://github.com/Kong/stapxx /tmp/stapxx",
    "stat /tmp/perf-ost || git clone https://github.com/openresty/openresty-systemtap-toolkit /tmp/perf-ost",
    "stat /tmp/perf-fg || git clone https://github.com/brendangregg/FlameGraph /tmp/perf-fg"
  })
  if not ok then
    return false, err
  end

  -- try compile the kernel module
  local out, err = perf.execute(ssh_execute_wrap(self, self.kong_ip,
          "sudo stap -ve 'probe begin { print(\"hello\\n\"); exit();}'"))
  if err then
    return nil, "systemtap failed to compile kernel module: " .. (out or "nil") ..
                " err: " .. (err or "nil") .. "\n Did you install gcc and kernel headers?"
  end

  return true
end

function _M:get_start_stapxx_cmd(sample, ...)
  if not self.systemtap_sanity_checked then
    local ok, err = check_systemtap_sanity(self)
    if not ok then
      return nil, err
    end
    self.systemtap_sanity_checked = true
  end

  -- find one of kong's child process hopefully it's a worker
  -- (does kong have cache loader/manager?)
  local pid, err = perf.execute(ssh_execute_wrap(self, self.kong_ip,
                      "pid=$(cat /usr/local/kong/pids/nginx.pid); " ..
                      "cat /proc/$pid/task/$pid/children | awk '{print $1}'"))
  if not pid or not tonumber(pid) then
    return nil, "failed to get Kong worker PID: " .. (err or "nil")
  end

  local args = table.concat({...}, " ")

  self.systemtap_dest_path = "/tmp/" .. tools.random_string()
  return ssh_execute_wrap(self, self.kong_ip,
            "sudo /tmp/stapxx/stap++ /tmp/stapxx/samples/" .. sample ..
            " --skip-badvars -D MAXSKIPPED=1000000 -x " .. pid ..
            " " .. args ..
            " > " .. self.systemtap_dest_path .. ".bt"
          )
end

function _M:get_wait_stapxx_cmd(timeout)
  return ssh_execute_wrap(self, self.kong_ip, "lsmod | grep stap_")
end

function _M:generate_flamegraph(title, opts)
  local path = self.systemtap_dest_path
  self.systemtap_dest_path = nil

  local out, _ = perf.execute(ssh_execute_wrap(self, self.kong_ip, "cat " .. path .. ".bt"))
  if not out or #out == 0 then
    return nil, "systemtap output is empty, possibly no sample are captured"
  end

  local ok, err = execute_batch(self, self.kong_ip, {
    -- if there's any error like ee with compiled bytecode, skip fix-lua-bt
    "/tmp/perf-ost/fix-lua-bt " .. path .. ".bt > " .. path .. ".fbt || true",
    "stat " .. path .. ".fbt || cp " .. path .. ".bt " .. path .. ".fbt",
    "/tmp/perf-fg/stackcollapse-stap.pl " .. path .. ".fbt > " .. path .. ".cbt",
    "/tmp/perf-fg/flamegraph.pl --title='" .. title .. "' " .. (opts or "") .. " " .. path .. ".cbt > " .. path .. ".svg",
  })
  if not ok then
    return false, err
  end

  local out, _ = perf.execute(ssh_execute_wrap(self, self.kong_ip, "cat " .. path .. ".svg"))

  perf.execute(ssh_execute_wrap(self, self.kong_ip, "rm -v " .. path .. ".*"),
              { logger = self.ssh_log.log_exec })

  return out
end

function _M:save_error_log(path)
  return perf.execute(ssh_execute_wrap(self, self.kong_ip,
          "cat " .. KONG_ERROR_LOG_PATH) .. " >'" .. path .. "'",
          { logger = self.ssh_log.log_exec })
end

function _M:save_pgdump(path)
  return perf.execute(ssh_execute_wrap(self, self.kong_ip,
      "docker exec -i kong-database psql -Ukong kong_tests") .. " >'" .. path .. "'",
      { logger = self.ssh_log.log_exec })
end

function _M:load_pgdump(path, dont_patch_service)
  local _, err = perf.execute("cat " .. path .. "| " .. ssh_execute_wrap(self, self.kong_ip,
      "docker exec -i kong-database psql -Ukong kong_tests"),
      { logger = self.ssh_log.log_exec })
  if err then
    return false, err
  end

  if dont_patch_service then
    return true
  end

  return perf.execute("echo \"UPDATE services set host='" .. self.worker_ip ..
                                                "', port=" .. UPSTREAM_PORT ..
                                                ", protocol='http';\" | " ..
      ssh_execute_wrap(self, self.kong_ip,
      "docker exec -i kong-database psql -Ukong kong_tests"),
      { logger = self.ssh_log.log_exec })
end

function _M:get_based_version()
  return self.daily_image_desc or perf.get_kong_version()
end

return _M
