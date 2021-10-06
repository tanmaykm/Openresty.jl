using Test
using Openresty
using HTTP

function createconfig(workdir::String, sudo::Bool=false, log_to_files::Bool=true, daemon::Bool=false)
    me = ENV["USER"]
    user = sudo ? "user $me $me;" : ""
    error_log = string("error_log ", log_to_files ? "$workdir/logs/error.log" : "/dev/stderr", " debug;")
    access_log = string("access_log ", log_to_files ? "$workdir/logs/access.log" : "/dev/stdout", ";")
    daemon_mode = daemon ? "on" : "off";

    cfg = """$user
daemon $daemon_mode;
worker_processes  1;
$error_log
events {
    worker_connections  1024;
}
http {
    $access_log
    $error_log
    lua_package_path 'OPENRESTY_LUA_PACKAGE_PATH';
    lua_package_cpath 'OPENRESTY_LUA_PACKAGE_CPATH';
    include       mime.types;
    server {
        listen 8080;
        server_name localhost;
        root $workdir/html;
        index index.html index.htm index.nginx-debian.html;
    }
}
"""
    cfgfile = joinpath(workdir, "test.conf")

    open(cfgfile, "w") do f
        println(f, cfg)
    end

    cfgfile
end

function test_nginx_config()
    body = ""

    @info("waiting for nginx to come up")
    # try for 10 secs
    while isempty(body)
        sleep(2)
        try
            resp = HTTP.get("http://127.0.0.1:8080/")
            body = String(resp.body)
        catch ex
            @info("nginx not ready yet...")
        end
    end

    isempty(body) && error("nginx did not come up")

    @info("testing nginx response")
    @test occursin("Welcome to OpenResty", body)
    nothing
end

function count_requests(logcontents::String)
    nrequests = 0
    for line in readlines(IOBuffer(logcontents))
        if match(r"\"GET\s\/\sHTTP\/1\.1\" 200", line) !== nothing
            nrequests += 1
        end
    end
    nrequests
end

function test(; sudo::Bool=false, log_to_files::Bool=true, daemon::Bool=false)
    @info("starting tests", sudo, log_to_files, daemon)
    workdir = mktempdir()
    mkpath(workdir)
    cfgfile = createconfig(workdir, sudo, log_to_files, daemon)
    nginx = OpenrestyCtx(workdir; sudo=sudo)

    accesslog = nothing
    errorlog = nothing
    accesslog2 = nothing
    errorlog2 = nothing
    if !log_to_files
        accesslog = errorlog = PipeBuffer()
    end

    @info("setting up Openresty", workdir)

    # incorrect lua path should throw error
    @test nothing === setup(nginx, cfgfile; lua_package_path="~/lua/?.lua", lua_package_cpath="~/lua/?.so")
    @test isfile(Openresty.conffile(nginx))
    confstr = read(Openresty.conffile(nginx), String)
    @test occursin("~/lua/?.lua", confstr)
    @test occursin(Openresty.luapath, confstr)
    @test occursin("$(Openresty.luapath);~/lua/?.lua;;", confstr)
    @test occursin("~/lua/?.so", confstr)
    @test occursin(Openresty.luacpath, confstr)
    @test occursin("$(Openresty.luacpath);~/lua/?.so;;", confstr)

    @info("starting Openresty")
    start(nginx; accesslog=accesslog, errorlog=errorlog)
    sleep(2)
    @test isfile(Openresty.pidfile(nginx))
    @test isrunning(nginx)

    test_nginx_config()

    @info("restarting Openresty")
    if !log_to_files
        # we need to create new IOs because they may be closed when the process restarts
        accesslog2 = errorlog2 = PipeBuffer()
        flush(accesslog)
    end
    restart(nginx; delay_seconds=2, accesslog=accesslog2, errorlog=errorlog2)

    sleep(2)
    @test isfile(Openresty.pidfile(nginx))
    @test isrunning(nginx)
    @test nothing === reopen(nginx)
    @test nothing === reload(nginx)

    test_nginx_config()

    @info("stopping Openresty")
    stop(nginx)
    sleep(2)
    @test !isfile(Openresty.pidfile(nginx))
    @test !isrunning(nginx)
    if log_to_files
        @test isfile(Openresty.accesslogfile(nginx))
        @test isfile(Openresty.errorlogfile(nginx))
    else
        flush(accesslog2)
        logbytes = readavailable(accesslog)
        logbytes2 = readavailable(accesslog2)
        @test !isempty(logbytes)
        @test !isempty(logbytes2)
        strbytes = String(logbytes) * String(logbytes2)
        @test findfirst("start worker processes", strbytes) !== nothing
        @test findfirst("HTTP", strbytes) !== nothing

        # test that when daemon is off, we are able to capture access logs even after a reload
        # but in daemon mode we are not able to (because of https://trac.nginx.org/nginx/ticket/1715#ticket)
        if daemon
            @test count_requests(strbytes) == 1
        else
            @test count_requests(strbytes) == 2
        end
    end

    @test_throws Exception setup(nginx, cfgfile)
    @test nothing === setup(nginx, cfgfile; force=true)
    @test nothing === setup(nginx, cfgfile; force=true, lua_package_path=["~/lua/?.lua", "/a/different/path"], lua_package_cpath=["~/lua/?.so", "/a/different/cpath"])

    @info("cleaning up")
    rm(workdir; recursive=true, force=true)
    @info("done")

    nothing
end

function sudo_available()
    cmd = `sudo -n ls`
    try
        run(pipeline(`sudo -n ls`, stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

for log_to_files in (true,false)
    for daemon in (true, false)
        test(; sudo=false, log_to_files=log_to_files, daemon=daemon)

        if sudo_available()
            test(; sudo=true, log_to_files=log_to_files)
        else
            @info("passwordless sudo not available, skipping sudo tests")
        end
    end
end
