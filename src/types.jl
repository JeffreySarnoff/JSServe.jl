"""
The string part of JSCode.
"""
struct JSString
    source::String
end

"""
Javascript code that supports interpolation of Julia Objects.
Construction of JSCode via string macro:
```julia
jsc = js"console.log(\$(some_julia_variable))"
```
This will decompose into:
```julia
jsc.source == [JSString("console.log("), some_julia_variable, JSString("\"")]
```
"""
struct JSCode
    source::Vector{Union{JSString, Any}}
end

"""
Represent an asset stored at an URL.
We try to always have online & local files for assets
If one gives an online resource, it will be downloaded, to host it locally.
"""
struct Asset
    media_type::Symbol
    # We try to always have online & local files for assets
    # If you only give an online resource, we will download it
    # to also be able to host it locally
    online_path::String
    local_path::String
    onload::Union{Nothing, JSCode}
end

"""
Encapsulates frontend dependencies. Can be used in the following way:

```Julia
const noUiSlider = Dependency(
    :noUiSlider,
    # js & css dependencies are supported
    [
        "https://cdn.jsdelivr.net/gh/leongersen/noUiSlider/distribute/nouislider.min.js",
        "https://cdn.jsdelivr.net/gh/leongersen/noUiSlider/distribute/nouislider.min.css"
    ]
)
# use the dependency on the frontend:
evaljs(session, js"\$(noUiSlider).some_function(...)")
```
jsrender will make sure that all dependencies get loaded.
"""
struct Dependency
    name::Symbol # The JS Module name that will get loaded
    assets::Vector{Asset}
    # The global -> Function name, JSCode -> the actual function code!
    functions::Dict{Symbol, JSCode}
end

"""
A web session with a user
"""
struct Session
    # indicates, whether session is in fuse mode, so it won't
    # send any messages, until fuse ends and send them all at once
    fusing::Base.RefValue{Bool}
    connections::Vector{WebSocket}
    observables::Dict{String, Tuple{Bool, Observable}} # Bool -> if already registered with Frontend
    message_queue::Vector{Dict{Symbol, Any}}
    dependencies::Set{Asset}
    on_document_load::Vector{JSCode}
    id::String
    js_fully_loaded::Channel{Bool}
    on_websocket_ready::Any
end


struct Routes
    table::Vector{Pair{Any, Any}}
end

function Routes(pairs::Pair...)
    return Routes([pairs...])
end

pattern_priority(x::Pair) = pattern_priority(x[1])
pattern_priority(x::String) = 1
pattern_priority(x::Tuple) = 2
pattern_priority(x::Regex) = 3

function Base.setindex!(routes::Routes, f, pattern)
    idx = findfirst(pair-> pair[1] == pattern, routes.table)
    if idx !== nothing
        routes.table[idx] = pattern => f
    else
        push!(routes.table, pattern => f)
    end
    # Sort for priority so that exact string matches come first
    sort!(routes.table, by = pattern_priority)
    return
end

function apply_handler(f, args...)
    f(args...)
end

function apply_handler(chain::Tuple, context, args...)
    f = first(chain)
    result = f(args...)
    apply_handler(Base.tail(chain), context, result...)
end

function delegate(routes::Routes, application, request::Request, args...)
    for (pattern, f) in routes.table
        match = match_request(pattern, request)
        if match !== nothing
            context = (
                routes = routes,
                application = application,
                request = request,
                match = match
            )
            return apply_handler(f, context, args...)
        end
    end
    # If no route is found we have a classic case of 404!
    # What a classic this response!
    return response_404("Didn't find route for $(request.target)")
end

function match_request(pattern::String, request)
    return request.target == pattern ? pattern : nothing
end

function match_request(pattern::Regex, request)
    return match(pattern, request.target)
end

function match_request(pattern::Tuple, request)
    return Matcha.matchat(pattern, request.target)
end


"""
The application one serves
"""
struct Application
    url::String
    port::Int
    sessions::Dict{String, Dict{String, Session}}
    server_task::Ref{Task}
    server_connection::Ref{TCPServer}
    routes::Routes
    websocket_routes::Routes
end
local_url(application::Application, url) = string("http://", application.url, ":", application.port, url)

WebSockets.getrawstream(io::IO) = io

function websocket_request()
    headers = [
        "Host" => "127.0.0.1",
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:68.0) Gecko/20100101 Firefox/68.0",
        "Accept" => "*/*",
        "Accept-Encoding" => "gzip, deflate, br",
        "Accept-Language" => "de,en-US;q=0.7,en;q=0.3",
        "Cache-Control" => "no-cache",
        "Connection" => "keep-alive, Upgrade",
        "Dnt" => "1",
        "Origin" => "https://localhost",
        "Pragma" => "no-cache",
        "Sec-Websocket-Extensions" => "permessage-deflate",
        "Sec-Websocket-Key" => "BL3d8I8KC5faPjubRM0riA==",
        "Sec-Websocket-Version" => "13",
        "Upgrade" => "websocket",
    ]
    msg = HTTP.Request(
        "GET",
        "/",
        headers,
        UInt8[],
        parent = nothing,
        version = v"1.1.0"
    )
    return Stream(msg, IOBuffer())
end


"""
warmup(application::Application)

Warms up the application, by sending a couple of request.
"""
function warmup(application::Application)
    yield() # yield to server task to give it a chance to get started
    task = application.server_task[]
    if Base.istaskdone(task)
        error("Webserver doesn't serve! Error: $(fetch(task))")
    end
    # Make a websocket request
    stream = websocket_request()
    try
        @async stream_handler(application, stream)
        write(stream, "blaaa")

    catch e
        # TODO make it not error so we can test this properly
        # This will error, since its not a propper websocket request
        @debug "Error in stream_handler" exception=e
    end
    target = AssetRegistry.register(JSCallLibLocal.local_path) # http target part
    asset_url = local_url(application, target)
    request = Request("GET", target)

    delegate(application.routes, application, request)

    if Base.istaskdone(task)
        error("Webserver doesn't serve! Error: $(fetch(task))")
    end
    resp = WebSockets.HTTP.get(asset_url, readtimeout=10, retries=1)
    if resp.status != 200
        error("Webserver didn't start succesfully")
    end
    return
end

function stream_handler(application::Application, stream::Stream)
    if WebSockets.is_upgrade(stream)
        WebSockets.upgrade(stream) do request, websocket
            delegate(
                application.websocket_routes, application, request, websocket
            )
        end
        return
    end
    f = HTTP.RequestHandlerFunction() do request
        delegate(
            application.routes, application, request,
        )
    end
    HTTP.handle(f, stream)
end

const MATCH_HEX = r"[\da-f]"
const MATCH_UUID4 = MATCH_HEX^8 * r"-" * (MATCH_HEX^4 * r"-")^3 * MATCH_HEX^12
const MATCH_SESSION_ID = MATCH_UUID4 * r"/" * MATCH_HEX^4

function serve_dom(context, dom)
    application = context.application
    session_id = string(uuid4())
    session = Session()
    application.sessions[session_id] = Dict("base" => session)
    html_dom = Base.invokelatest(dom, session, context.request)
    return html(dom2html(session, session_id, html_dom))
end

"""
Application(
        dom, url::String, port::Int;
        verbose = false
    )

Creates an application that manages the global server state!
"""
function Application(
        dom, url::String, port::Int;
        verbose = false,
        routes = Routes(
            "/" => ctx-> serve_dom(ctx, dom),
            r"/assetserver/" * MATCH_HEX^40 * r"-.*" => file_server,
            r".*" => (context)-> response_404()
        ),
        websocket_routes = Routes(
            r"/" * MATCH_SESSION_ID => websocket_handler
        )
    )

    application = Application(
        url, port, Dict{String, Dict{String, Session}}(),
        Ref{Task}(), Ref{TCPServer}(),
        routes,
        websocket_routes
    )
    try
        start(application; verbose=verbose)
        # warmup server!
        warmup(application)
    catch e
        close(application)
        rethrow(e)
    end

    return application
end

function isrunning(application::Application)
    return (isassigned(application.server_task) &&
        isassigned(application.server_connection) &&
        !istaskdone(application.server_task[]) &&
        isopen(application.server_connection[]))
end

function Base.close(application::Application)
    # Closing the io connection should shut down the HTTP listen loop
    for (id, clients) in application.sessions
        for (id, session) in clients
            close(session)
        end
    end

    if isassigned(application.server_connection)
        close(application.server_connection[])
        @assert !isopen(application.server_connection[])
    end
    # For good measures, wait until the task finishes!
    if isassigned(application.server_task)
        try
            wait(application.server_task[])
            @assert !isdone(application.server_connection[])
        catch e
            @debug "Server task failed with an (expected) exception on close" exception=e
        end
    end
    # Sometimes, the first request after closing will still go through
    # see: https://github.com/JuliaWeb/HTTP.jl/pull/494
    # We need to make sure, that we are the ones making this request,
    # So that a newly opened connection won't get a faulty response from this server!
    try
        app_url = JSServe.local_url(application, "/")
        while true
            x = HTTP.get(app_url, readtimeout=1, retries=1)
            x.status != 200 && break
        end
    catch e
        # This is expected to fail!
        @debug "Failed get request successfully after closing server!" exception=e
    end
    @assert !isrunning(application)
end

function start(application::Application; verbose=false)
    isrunning(application) && return
    address = Sockets.InetAddr(parse(Sockets.IPAddr, application.url), application.port)
    ioserver = Sockets.listen(address)
    application.server_connection[] = ioserver
    # pass tcp connection to listen, so that we can close the server
    application.server_task[] = @async HTTP.listen(
            application.url, application.port; server=ioserver, verbose=verbose
        ) do stream::Stream
        Base.invokelatest(stream_handler, application, stream)
    end
    return
end


function route!(application::Application, pattern_f::Pair)
    application.routes[pattern_f[1]] = pattern_f[2]
end

function route!(f, application::Application, pattern)
    route!(application, pattern => f)
end

function websocket_route!(application::Application, pattern_f::Pair)
    application.webscoket_routes[pattern_f[1]] = pattern_f[2]
end
