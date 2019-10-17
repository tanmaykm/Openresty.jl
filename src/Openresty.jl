module Openresty

include("../deps/deps.jl")

export OpenrestyCtx
export setup, start, stop, restart, isrunning, reopen, reload

const nginxbindir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/sbin"))
const htmltemplatedir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/html"))
const conftemplatedir = abspath(joinpath(dirname(@__FILE__), "../deps/usr/nginx/conf"))
const lualib = joinpath(dirname(dirname(nginxbindir)), "lualib")
const luapath = joinpath(lualib, "?.lua")

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
    pid::Union{Int,Nothing}

    function OpenrestyCtx(workdir)
        ctx = new(workdir, nothing)
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
luadir(ctx::OpenrestyCtx) = joinpath(ctx.workdir, "lua")

function setup(ctx::OpenrestyCtx, configfile::Union{String,Nothing}=nothing; force::Bool=false, reset_templates::Bool=force, lua_package_path::Union{String,Vector{String},Nothing}=nothing)
    existing_setup = isdir(confdir(ctx)) && isdir(htmldir(ctx)) && isdir(logsdir(ctx))

    existing_setup && !force && error("setup already exists, specify force=true to overwrite")
    validate_user_lua_package_path(lua_package_path)

    # make the workdir
    for path in (htmldir(ctx), confdir(ctx), logsdir(ctx), joinpath(luadir(ctx), "user"))
        isdir(path) || mkpath(path)
    end

    # place configuration file
    if force || !isfile(conffile(ctx))
        # copy over bundled base configurations
        cp(conftemplatedir, confdir(ctx); force=true)
        #run(`cp -R -f $(joinpath(conftemplatedir, ".")) $(confdir(ctx))`)
        # copy over provided configuration
        (configfile !== nothing) && cp(configfile, conffile(ctx); force=true)
        set_lua_package_path(ctx, lua_package_path)
    end

    # place lua files
    isdir(joinpath(luadir(ctx), "lualib")) || cp(lualib, joinpath(luadir(ctx), "lualib"); force=true)
    setup_user_lua_package_from_path(ctx, lua_package_path; overwrite=reset_templates)

    # copy over bundled templates
    (reset_templates || !existing_setup) && cp(htmltemplatedir, htmldir(ctx); force=true)
    #run(`cp -R -f $(joinpath(htmltemplatedir, ".")) $(htmldir(ctx))`)

    #chmod(luadir(ctx), 0o755; recursive=true)
    #chmod(htmldir(ctx), 0o755; recursive=true)

    nothing
end

validate_user_lua_package_path(lua_package_path::Nothing) = nothing
validate_user_lua_package_path(lua_package_path::String) = isdir(lua_package_path) || error("not a directory: $lua_package_path")
function validate_user_lua_package_path(lua_package_path::Vector{String})
    for path in lua_package_path
        validate_user_lua_package_path(path)
    end
end

function user_lua_lib_folder(ctx::OpenrestyCtx, lua_package_path::String)
    basefolder = basename(lua_package_path)
    joinpath(luadir(ctx), "user", basefolder)
end

setup_user_lua_package_from_path(ctx::OpenrestyCtx, lua_package_path::Nothing; overwrite::Bool=false) = nothing
function setup_user_lua_package_from_path(ctx::OpenrestyCtx, lua_package_path::Vector{String}; overwrite::Bool=false)
    for path in lua_package_path
        setup_user_lua_package_from_path(ctx, path; overwrite=overwrite)
    end
end
function setup_user_lua_package_from_path(ctx::OpenrestyCtx, lua_package_path::String; overwrite::Bool=false)
    userfolder = user_lua_lib_folder(ctx, lua_package_path)
    (overwrite || !isdir(userfolder)) && cp(lua_package_path, userfolder; force=true)
    nothing
end

"""
Replace all occurrences of OPENRESTY_LUA_PACKAGE_PATH in the configuration file by
actual lua package path
"""
function set_lua_package_path(ctx::OpenrestyCtx, lua_package_path::Union{String,Vector{String},Nothing}=nothing)
    config = read(conffile(ctx), String)
    all_lua_paths = [joinpath(luadir(ctx), "lualib")]
    if isa(lua_package_path, String)
        push!(all_lua_paths, user_lua_lib_folder(ctx, lua_package_path))
    elseif isa(lua_package_path, Vector{String})
        for path in lua_package_path
            push!(all_lua_paths, user_lua_lib_folder(ctx, path))
        end
    end
    all_lua_paths = [joinpath(path, "?.lua") for path in all_lua_paths]
    pathstr = join(all_lua_paths, ';') * ";;"

    config = replace(config, "OPENRESTY_LUA_PACKAGE_PATH" => pathstr)
    open(conffile(ctx), "w") do f
        write(f, config)
    end
    nothing
end

function start(ctx::OpenrestyCtx)
    config = conffile(ctx)
    @debug("starting \"$openresty -p $(ctx.workdir)\" from \"$nginxbindir\"")
    command = Cmd(`$openresty -p $(ctx.workdir)`; detach=true, dir=nginxbindir)
    run(command; wait=false)
    sleep(1)
    readpid(ctx)
    nothing
end

isrunning(ctx::OpenrestyCtx) = (ctx.pid !== nothing) ? isrunning(ctx, ctx.pid) : false
function isrunning(ctx::OpenrestyCtx, pid::Int)
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
        command = Cmd(`$openresty -p $(ctx.workdir) -s $signal`; dir=nginxbindir)
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
