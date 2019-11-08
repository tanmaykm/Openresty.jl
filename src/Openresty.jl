module Openresty

include("../deps/deps.jl")

export OpenrestyCtx
export setup, start, stop, restart, isrunning, reopen, reload

const nginxbindir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/sbin"))
const htmltemplatedir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/html"))
const conftemplatedir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/conf"))
const luapath = joinpath(dirname(dirname(nginxbindir)), "lualib", "?.lua")
const luacpath = joinpath(dirname(dirname(nginxbindir)), "lualib", "?.so")

function __init__()
    check_deps()
    if !isdir(htmltemplatedir)
        error("$(htmltemplatedir) does not exist, Please re-run Pkg.build(\"Openresty\"), and restart Julia.")
    end
    if !isdir(conftemplatedir)
        error("$(conftemplatedir) does not exist, Please re-run Pkg.build(\"Openresty\"), and restart Julia.")
    end
end

mutable struct OpenrestyCtx
    workdir::String
    sudo::Bool
    pid::Union{Int,Nothing}

    function OpenrestyCtx(workdir; sudo::Bool=false)
        ctx = new(workdir, sudo, nothing)
        readpid(ctx)
        ctx
    end
end

htmldir(ctx::OpenrestyCtx) = joinpath(ctx.workdir, "html")
confdir(ctx::OpenrestyCtx) = joinpath(ctx.workdir, "conf")
conffile(ctx::OpenrestyCtx) = joinpath(confdir(ctx), "nginx.conf")
logsdir(ctx::OpenrestyCtx) = joinpath(ctx.workdir, "logs")
pidfile(ctx::OpenrestyCtx) = joinpath(logsdir(ctx), "nginx.pid")
accesslogfile(ctx::OpenrestyCtx) = joinpath(logsdir(ctx), "access.log")
errorlogfile(ctx::OpenrestyCtx) = joinpath(logsdir(ctx), "error.log")

function setup(ctx::OpenrestyCtx, configfile::Union{String,Nothing}=nothing; force::Bool=false, reset_templates::Bool=force, lua_package_path::Union{String,Vector{String},Nothing}=nothing, lua_package_cpath::Union{String,Vector{String},Nothing}=nothing)
    existing_setup = isdir(confdir(ctx)) && isdir(htmldir(ctx)) && isdir(logsdir(ctx))

    existing_setup && !force && error("setup already exists, specify force=true to overwrite")

    # make the workdir
    for path in (htmldir(ctx), confdir(ctx), logsdir(ctx))
        isdir(path) || mkpath(path)
    end

    # place configuration file
    if force || !isfile(conffile(ctx))
        # copy over bundled base configurations
        cp(conftemplatedir, confdir(ctx); force=true)
        # copy over provided configuration
        (configfile !== nothing) && cp(configfile, conffile(ctx); force=true)
        set_lua_package_path(ctx, lua_package_path, lua_package_cpath)
    end

    # copy over bundled templates
    (reset_templates || !existing_setup) && cp(htmltemplatedir, htmldir(ctx); force=true)

    nothing
end

"""
Replace all occurrences of OPENRESTY_LUA_PACKAGE_PATH in the configuration file by
actual lua package path
"""
function set_lua_package_path(ctx::OpenrestyCtx, lua_package_path::Union{String,Vector{String},Nothing}=nothing, lua_package_cpath::Union{String,Vector{String},Nothing}=nothing)
    config = read(conffile(ctx), String)
    all_lua_paths = [luapath]
    all_lua_cpaths = [luacpath]
    if isa(lua_package_path, String)
        push!(all_lua_paths, lua_package_path)
    elseif isa(lua_package_path, Vector{String})
        append!(all_lua_paths, lua_package_path)
    end
    if isa(lua_package_cpath, String)
        push!(all_lua_cpaths, lua_package_cpath)
    elseif isa(lua_package_cpath, Vector{String})
        append!(all_lua_cpaths, lua_package_cpath)
    end
    pathstr = join(all_lua_paths, ';') * ";;"
    cpathstr = join(all_lua_cpaths, ';') * ";;"

    config = replace(config, "OPENRESTY_LUA_PACKAGE_PATH" => pathstr)
    config = replace(config, "OPENRESTY_LUA_PACKAGE_CPATH" => cpathstr)
    open(conffile(ctx), "w") do f
        write(f, config)
    end
    nothing
end

function start(ctx::OpenrestyCtx)
    config = conffile(ctx)
    @debug("starting", openresty, workdir=ctx.workdir, nginxbindir, sudo=ctx.sudo)
    command = Cmd(ctx.sudo ? `sudo $openresty -p $(ctx.workdir)` : `$openresty -p $(ctx.workdir)`; detach=true, dir=nginxbindir)
    run(command; wait=false)
    sleep(1)
    readpid(ctx)
    nothing
end

isrunning(ctx::OpenrestyCtx) = (ctx.pid !== nothing) ? isrunning(ctx, ctx.pid) : false
function isrunning(ctx::OpenrestyCtx, pid::Int)
    # we do have read permission on cmdline even if process was started with sudo
    cmdlinefile = "/proc/$pid/cmdline"
    if isfile(cmdlinefile)
        cmdline = read(cmdlinefile, String)
        @debug("found command line", cmdlinefile, cmdline , openresty, ctx.workdir)
        if occursin(openresty, cmdline) && occursin(ctx.workdir, cmdline)
            # process still running
            return true
        end
    end

    ctx.pid = nothing
    rm(pidfile(ctx); force=true)
    false
end

function stop(ctx::OpenrestyCtx; grace_seconds::Int=2)
    if isrunning(ctx)
        signalquit(ctx)
        sleep(grace_seconds)
        isrunning(ctx) && signalstop(ctx)
        while isrunning(ctx)
            @debug("waiting for shutdown...")
            sleep(grace_seconds+1)
        end
    end
    nothing
end

function restart(ctx::OpenrestyCtx; delay_seconds::Int=0)
    stop(ctx)
    (delay_seconds > 0) && sleep(delay_seconds)
    start(ctx)
end
reopen(ctx::OpenrestyCtx) = signalreopen(ctx)
reload(ctx::OpenrestyCtx) = signalreload(ctx)

signalstop(ctx::OpenrestyCtx) = signal(ctx, "stop")
signalquit(ctx::OpenrestyCtx) = signal(ctx, "quit")
signalreopen(ctx::OpenrestyCtx) = signal(ctx, "reopen")
signalreload(ctx::OpenrestyCtx) = signal(ctx, "reload")
function signal(ctx::OpenrestyCtx, signal::String)
    if isrunning(ctx)
        @debug("sending signal $signal")
        command = Cmd(ctx.sudo ? `sudo $openresty -p $(ctx.workdir) -s $signal` : `$openresty -p $(ctx.workdir) -s $signal`; dir=nginxbindir)
        run(command)
    end
    nothing
end

function readpid(ctx::OpenrestyCtx)
    pfile = pidfile(ctx)
    if isfile(pfile)
        ctx.pid = parse(Int, read(pidfile(ctx), String))
        isrunning(ctx)
    end
    nothing
end

end
