--[[
Copyright (c) 2018 Eric Liu.
All Rights Reserved.
--]]

local errHandler = require("try-catch-finally");
local requests   = require("requests");
local inspect    = require("inspect");
local List       = require("list");
local siteConfig = require("luarocks.site_config");

local __version__ = "0.1.0";

local config = {};
local speedtestConfigUrl = "://www.speedtest.net/speedtest-config.php";
local system = nil;
local proc = nil;

local function BuildRequest(url, data, header, bump, secure)
    --[[
        Build a url request
        This function automatically adds a User-Agent header to all requests
    --]]
    data = data or nil;
    header = header or {};
    bump = bump or "0";
    secure = secure or false;

    local scheme = "http";
    local schemedUrl = url;
    local delim = "?";
    
    if (string.sub(url,1,1) == ":") then
        if (secure == true) then
            scheme = "https";
        end
        schemedUrl = scheme..url;
    end

    if (string.match( url, "?")) then
        delim = "&";
    end

    local finalUrl = string.format("%s%sx=%s.%s", schemedUrl, delim, os.time()*1000, bump);
    local headers = { ["Cache-Control"] = "no-cache" };
    -- local headers = { ["Cache-Control"] = "no-cache", ["Accept-Encoding"] = "gzip" };

    return finalUrl, headers;
end

local function CatchRequest(url, headers, passRes)
    local t1 = os.time();
    passRes["response"] = requests.request("GET", url, headers);
    local delta = os.time() - t1;
    print("delta time is "..delta.."s");
end

local function IncreseList(list, xmlBody)
    if type(xmlBody) ~= "table" then
        return;
    end
    for key, value in pairs(xmlBody) do
        if key ~= "xml" then
            list:push(value);
        end
    end
end

local function GetAttributeByTagName(xmlBody, tagName)
    --[[
        Retrieve an attribute from an XML document and return it in a
        consistent format
    --]]
    local list = List:new();
    if xmlBody["xml"] == tagName then
        return xmlBody;
    end
    IncreseList(list, xmlBody);
    while not list:empty()
    do
        local value = list:pop();
        if value["xml"] == tagName then
            return value;
        else
            IncreseList(list, value);
        end
    end
end

local function StrSplit(inputStr, sep)
    -- Split a string to a table
    local tab = {};
    local index = 1;
    for str in string.gmatch(inputStr, "([^"..sep.."]+)") do
        -- Use str as key for index quickly
        tab[str] = true;
        index = index+1;
    end
    return tab;
end

local function FindLast(haystack, needle)
    -- Find the last index of character in the string
    local i = string.match(haystack, ".*"..needle.."()");
    if i == nil then
        return nil 
    else 
        return i-1 
    end
end

local function GetConfig()
    --[[
        Download the speedtest.net configuration and return only the data
        we are interested in
    --]]
    local url, headers = BuildRequest(speedtestConfigUrl);
    local passRes = {};
    CatchRequest(url, headers, passRes);
    local xmlBody = passRes["response"].xml();
    local serverConfig = GetAttributeByTagName(xmlBody, "server-config");
    local download = GetAttributeByTagName(xmlBody, "download");
    local upload = GetAttributeByTagName(xmlBody, "upload");
    local client = GetAttributeByTagName(xmlBody, "client");
    local ignoreServers = StrSplit(serverConfig["ignoreids"], ",");
    local ratio = tonumber(upload["ratio"]);
    local uploadMax = tonumber(upload["maxchunkcount"]);
    local upSizes = {32768, 65536, 131072, 262144, 524288, 1048576, 7340032};
    local sizes = {
        ["download"] = {350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000},
        ["upload"] = {};
    };

    for index=1, #upSizes do
        if index >= ratio then
            table.insert(sizes["upload"], upSizes[index]);
        end
    end

    local sizeCount = #sizes["upload"];
    local uploadCount = math.ceil(uploadMax/sizeCount);
    local counts = {
        ["upload"] = uploadCount,
        ["download"] = download["threadsperurl"]
    };
    local threads = {
        ["upload"] = upload["threads"],
        ["download"] = serverConfig["threadcount"]*2
    };
    local length = {
        ["upload"] = upload["testlength"],
        ["download"] = download["testlength"]
    };
    
    return {
        ["client"] = client,
        ["ignoreServers"] = ignoreServers,
        ["sizes"] = sizes,
        ["counts"] = counts,
        ["threads"] = threads,
        ["length"] = length,
        ["uploadMax"] = uploadCount*sizeCount
    }
end

local function CalcDistance(oriLat, oriLon, destLat, destLon)
    local radius = 6371  -- km
    local dlat = math.rad(destLat - oriLat);
    local dlon = math.rad(destLon - oriLon);
    local a = (math.sin(dlat / 2) * math.sin(dlat / 2) +
               math.cos(math.rad(oriLat)) *
               math.cos(math.rad(destLat)) * math.sin(dlon / 2) *
               math.sin(dlon / 2));
    local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    local d = radius * c;

    return d;
end

local function ParseObtainedServers(config, passRes, storedServers)
    --[[
        Parse all obtained servers, exclude the ignore ones and
        store them in a new table
    ]]
    -- Add the status_code check to avoid "Segmentation fault: 11" 
    if passRes["response"].status_code ~= 200 then
        return;
    end
    local xmlBody = passRes["response"].xml();
    local servers = GetAttributeByTagName(xmlBody, "servers");
    for serverIndex, server in ipairs(servers) do
        repeat
            if config["ignoreServers"][server["id"]] ~= nil then
                break;
            end
            local d = CalcDistance(config["client"]["lat"],
                config["client"]["lon"], server["lat"], server["lon"]);
            server["d"] = d;
            storedServers[d] = server;
        until true
    end
end

local function GetServers(config)
    -- Retrieve a the list of speedtest.net servers
    local urls = {
        "://www.speedtest.net/speedtest-servers-static.php",
        "http://c.speedtest.net/speedtest-servers-static.php",
        "://www.speedtest.net/speedtest-servers.php",
        "http://c.speedtest.net/speedtest-servers.php"
    };
    local allServers = {};

    for index, value in ipairs(urls) do
        local url, headers = BuildRequest(string.format("%s?threads=%s", value, 
            config["threads"]["download"]));
        local passRes = {};
        local exceptionFlag = false;
        errHandler
        .try(CatchRequest, url, headers, passRes)
        .catch(
        function (ex)
            print(ex);
            exceptionFlag = true;
        end)
        if exceptionFlag == false then
            errHandler
            .try(ParseObtainedServers, config, passRes, allServers)
            .catch(
                function (ex)
                    print(ex);
                end
            )
        end
    end

    return allServers;
end

local function BuildUserAgent()
    --[[
        Build a Mozilla/5.0 compatible User-Agent string
        Currently, useAgent info is hard coded, will imporve
        it later
    --]]
    local name = "speedtest-lua";
    local versionInfo = string.format("%s/%s", name, __version__);
    local systemInfo = string.format("%s; U; %s; en-us", system, proc);
    local userAgent = "Mozilla/5.0 "..systemInfo.." ".._VERSION.." "
        .."(KHTML, like Gecko) "..versionInfo;
    return userAgent;
end

local function GetClosestServers(servers, limit)
    --[[
        Limit servers to the closest speedtest.net servers based on
        geographic distance
    --]]
    limit = limit or 5;
    local closest = {};
    local keyTable = {};
    for key, _ in pairs(servers) do
        table.insert(keyTable, key);
    end
    table.sort(keyTable);
    for count=1,limit do
        table.insert(closest, servers[keyTable[count]]);
    end
    return closest;
end

local function TestConnection(url, passRes)
    local start = os.clock();
    passRes["response"] = requests.request("GET", url, headers);
    local diff = (os.clock() - start)*1000*1000;
    table.insert(passRes["diffTime"], diff);
end

local function GetBestServer(servers) 
    --[[
        Perform a speedtest.net "ping" to determine which speedtest.net
        server has the lowest latency
    --]]
    local closestServers = GetClosestServers(servers);
    local userAgent = BuildUserAgent();
    local results = {};

    for _, server in ipairs(closestServers) do
        local lastIndex = FindLast(server["url"], "/");
        if lastIndex ~= nil then
            local url = string.sub(server["url"], 1, lastIndex-1);
            local stamp = os.time()*1000;
            local latencyUrl = string.format("%s/latency.txt?x=%s",
                url, stamp);
            local cum = {};
            for i = 0, 2 do
                local thisLatencyUrl = string.format("%s.%s", latencyUrl, i);
                local passRes = { ["diffTime"] = {} };
                errHandler
                .try(TestConnection, thisLatencyUrl, passRes)
                .catch(
                    function (ex)
                        table.insert(cum, 3600);
                        print(ex);
                    end
                )
                local text = string.sub(passRes["response"].text,1,9);
                if passRes["response"].status_code == 200 and
                text == "test=test" then
                    table.insert(cum, passRes["diffTime"][1]);
                else
                    table.insert(cum, 3600);
                end
            end
            local ave = 0;
            for _, value in ipairs(cum) do
                ave = ave + value;
            end
            ave = ave / 3;
            results[ave] = server;
        end
    end
    local keyTable = {};
    for key, _ in pairs(results) do
        table.insert(keyTable, key);
    end
    table.sort(keyTable);
    print("Best server average ping is:"..keyTable[1].."ms");
    return results[keyTable[1]];
end

local function SystemDetection()
    --[[
        Detect the system info
        Currently, it depends on luarocks
    --]]
    system = siteConfig.LUAROCKS_UNAME_S or io.popen("uname -s"):read("*l");
    proc = siteConfig.LUAROCKS_UNAME_M or io.popen("uname -m"):read("*l");
    if proc:match("i[%d]86") then
        proc = "32bit"
    elseif proc:match("amd64") or proc:match("x86_64") then
        proc = "64bit"
    end
end

local function TestDownload(config, bestServer)
    -- Test download speed against speedtest.net
    local urls = {};
    local requests = {};
    for _, size in ipairs(config["sizes"]["download"]) do
        for index = 1, config["counts"]["download"] do
            local lastIndex = FindLast(bestServer["url"], "/");
            if lastIndex ~= nil then
                local bestUrl = string.sub(bestServer["url"], 1, lastIndex-1);
                local url = string.format("%s/random%sx%s.jpg", 
                    bestUrl, size, size);
                local finalUrl, header = BuildRequest(url, nil, nil, index-1);
                local request = { ["url"] = finalUrl, ["header"] = header };
                table.insert(urls, url);
                table.insert(requests, request);
            end
        end
    end
    
    local requestCount = #urls;
    -- local requests = {};
    -- for _, url in iparis(urls) do
    -- end
    print("urls size is "..#urls);
    print("requests size is "..#requests);
    print(inspect(requests));
end

local function Shell()
    SystemDetection();
    print("Retrieving speedtest.net configuration...");
    local config = GetConfig();
    print(inspect(config));
    -- print(string.format("Testing from %s (%s)...", config["client"]["isp"], 
    --     config["client"]["ip"]));
    -- print("Retrieving speedtest.net server list...");
    -- local servers = GetServers(config);
    -- print("Selecting best server based on ping...");
    -- local bestServer = GetBestServer(servers);
    -- print(inspect(bestServer));
    -- print("Testing download speed");
    -- TestDownload(config, bestServer);

end

local function main()

    errHandler
    .try(Shell)
    .catch(function (ex)
        print(ex);
    end)
    .finally(function ()
        print("in finally");
    end)

    print("main end");
end

main();