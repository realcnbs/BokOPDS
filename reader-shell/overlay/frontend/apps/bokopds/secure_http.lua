local http = require("socket.http")
local https = require("ssl.https")
local mime = require("mime")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")

local SecureHttp = {}

local DEFAULT_HTTPS_PORT = "443"
local DEFAULT_HTTP_PORT = "80"
local MAX_REDIRECTS = 5

local function normalizedHost(host)
    host = tostring(host or ""):lower():gsub("%.$", "")
    return host
end

local function isLoopback(host)
    host = normalizedHost(host):gsub("^%[", ""):gsub("%]$", "")
    return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function parsedUrl(value)
    local parsed = socket_url.parse(value or "") or {}
    parsed.scheme = tostring(parsed.scheme or ""):lower()
    parsed.host = normalizedHost(parsed.host)
    if parsed.port == "" then parsed.port = nil end
    return parsed
end

local function effectivePort(parsed)
    if parsed.port then return tostring(parsed.port) end
    if parsed.scheme == "https" then return DEFAULT_HTTPS_PORT end
    if parsed.scheme == "http" then return DEFAULT_HTTP_PORT end
    return ""
end

function SecureHttp.validateUrl(value)
    local parsed = parsedUrl(value)
    if parsed.host == "" then return nil, "URL has no host" end
    if parsed.user or parsed.password then
        return nil, "credentials embedded in URLs are not supported"
    end
    if parsed.scheme == "https" then return true end
    if parsed.scheme == "http" and isLoopback(parsed.host) and
            os.getenv("BOKOPDS_ALLOW_INSECURE_LOOPBACK") == "1" then return true end
    if parsed.scheme == "http" then return nil, "remote URL must use HTTPS" end
    return nil, "unsupported URL scheme"
end

function SecureHttp.sameOrigin(first, second)
    local a, b = parsedUrl(first), parsedUrl(second)
    return a.scheme ~= "" and a.scheme == b.scheme and a.host == b.host and
        effectivePort(a) == effectivePort(b)
end

local function dnsPatternMatches(pattern, hostname)
    pattern, hostname = normalizedHost(pattern), normalizedHost(hostname)
    if pattern == hostname then return true end
    local suffix = pattern:match("^%*%.(.+)$")
    if not suffix or suffix:find("%*", 1, true) then return false end
    local prefix = hostname:sub(1, -#suffix - 2)
    return prefix ~= "" and not prefix:find("%.", 1, true) and
        hostname:sub(-#suffix - 1) == "." .. suffix
end

local function values(value)
    if type(value) ~= "table" then return { value } end
    if value[1] ~= nil then return value end
    return { value }
end

local function certificateNames(certificate)
    local dns_names, ip_names = {}, {}
    local ok_extensions, extensions = pcall(certificate.extensions, certificate)
    if ok_extensions and type(extensions) == "table" then
        local alternative_names = extensions["2.5.29.17"] or extensions.subjectAltName
        if type(alternative_names) == "table" then
            for _, name in ipairs(values(alternative_names.dNSName)) do
                if type(name) == "string" then table.insert(dns_names, name) end
            end
            for _, name in ipairs(values(alternative_names.iPAddress)) do
                if type(name) == "string" then table.insert(ip_names, name) end
            end
        end
    end
    if #dns_names == 0 and #ip_names == 0 then
        local ok_subject, subject = pcall(certificate.subject, certificate)
        if ok_subject and type(subject) == "table" then
            for _, item in ipairs(subject) do
                if item.name == "commonName" and type(item.value) == "string" then
                    table.insert(dns_names, item.value)
                end
            end
        end
    end
    return dns_names, ip_names
end

local function looksLikeIp(hostname)
    return hostname:find(":", 1, true) ~= nil or hostname:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

function SecureHttp.certificateMatchesHost(certificate, hostname)
    hostname = normalizedHost(hostname):gsub("^%[", ""):gsub("%]$", "")
    if not certificate or hostname == "" then return false end
    local dns_names, ip_names = certificateNames(certificate)
    if looksLikeIp(hostname) then
        for _, name in ipairs(ip_names) do
            if normalizedHost(name) == hostname then return true end
        end
        return false
    end
    for _, name in ipairs(dns_names) do
        if dnsPatternMatches(name, hostname) then return true end
    end
    return false
end

local function secureFactory(hostname)
    local ca_file = os.getenv("SSL_CERT_FILE")
    if not ca_file or ca_file == "" then
        error("SSL_CERT_FILE is not configured")
    end
    local base_factory = https.tcp({
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = ca_file,
    })
    return function()
        local connection = base_factory()
        local connect = connection.connect
        function connection:connect(host, port)
            local ok, err = connect(self, host, port)
            if not ok then return ok, err end
            local certificate = self:getpeercertificate()
            if not SecureHttp.certificateMatchesHost(certificate, hostname) then
                self:close()
                return nil, "TLS certificate does not match " .. hostname
            end
            return 1
        end
        return connection
    end
end

local function boundedTableSink(chunks, maximum)
    local total = 0
    local timed_sink = socketutil.table_sink(chunks)
    return function(chunk, err)
        if chunk then
            total = total + #chunk
            if maximum and total > maximum then return nil, "response is too large" end
        end
        return timed_sink(chunk, err)
    end
end

local function boundedFileSink(file, maximum)
    local total = 0
    local timed_sink = socketutil.file_sink(file)
    return function(chunk, err)
        if chunk then
            total = total + #chunk
            if maximum and total > maximum then
                file:close()
                return nil, "response is too large"
            end
        end
        return timed_sink(chunk, err)
    end
end

local function oneRequest(options, request_url)
    local parsed = parsedUrl(request_url)
    local chunks, file, sink
    if options.output_path then
        file = io.open(options.output_path, "wb")
        if not file then return nil, nil, nil, "could not open download file" end
        sink = boundedFileSink(file, options.max_bytes)
    else
        chunks = {}
        sink = boundedTableSink(chunks, options.max_bytes)
    end
    local request_headers = {}
    for name, value in pairs(options.headers or {}) do
        request_headers[name] = value
    end
    local request = {
        url = request_url,
        method = "GET",
        headers = request_headers,
        sink = sink,
        redirect = false,
    }
    if parsed.scheme == "https" then request.create = secureFactory(parsed.host) end
    if options.username and options.username ~= "" and
            SecureHttp.sameOrigin(request_url, options.auth_origin or options.url) then
        request_headers["Authorization"] = "Basic " .. mime.b64(
            options.username .. ":" .. (options.password or ""))
    end
    local ok, result, code, headers, status = pcall(http.request, request)
    if file then pcall(file.close, file) end
    if not ok then return nil, nil, nil, tostring(result) end
    return code, headers or {}, chunks and table.concat(chunks) or nil, status
end

function SecureHttp.request(options)
    local current = assert(options.url)
    socketutil:set_timeout(options.block_timeout or 15, options.total_timeout or 60)
    local response
    local ok, failure = pcall(function()
        for redirect = 0, MAX_REDIRECTS do
            local valid, validation_error = SecureHttp.validateUrl(current)
            if not valid then error(validation_error) end
            local code, headers, body, status = oneRequest(options, current)
            if not code then error(status or "network request failed") end
            if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                if redirect == MAX_REDIRECTS then error("too many redirects") end
                local location = headers.location
                if not location or location == "" then error("redirect has no location") end
                current = socket_url.absolute(current, location)
                if options.output_path then os.remove(options.output_path) end
            else
                response = { code = code, headers = headers, body = body, status = status,
                    final_url = current }
                return
            end
        end
    end)
    socketutil:reset_timeout()
    if not ok then
        if options.output_path then os.remove(options.output_path) end
        return { ok = false, error = tostring(failure):gsub("^[^:]+:%d+: ", "") }
    end
    response.ok = response.code == 200
    if not response.ok then response.error = response.status or tostring(response.code) end
    return response
end

return SecureHttp
