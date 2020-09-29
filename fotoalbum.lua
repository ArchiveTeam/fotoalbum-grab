dofile("table_show.lua")
dofile("urlcode.lua")
local urlparse = require("socket.url")
local http = require("socket.http")

local item_value = os.getenv('item_value')
local item_type = os.getenv('item_type')
local item_dir = os.getenv('item_dir')
local warc_file_base = os.getenv('warc_file_base')

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false

local discovered = {}
local ids = {}

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

discover_item = function(type_, name, tries)
  if tries == nil then
    tries = 0
  end
  name = urlparse.escape(urlparse.unescape(name))
  item = type_ .. ':' .. name
  if discovered[item] then
    return true
  end
  io.stdout:write("Discovered item " .. item .. ".\n")
  io.stdout:flush()
  local body, code, headers, status = http.request(
    "http://blackbird-amqp.meo.ws:23038/fotoalbum-sali9c89alki20g/",
    item
  )
  if code == 200 or code == 409 then
    discovered[item] = true
    return true
  elseif code == 404 then
    io.stdout:write("Project key not found.\n")
    io.stdout:flush()
  elseif code == 400 then
    io.stdout:write("Bad format.\n")
    io.stdout:flush()
  else
    io.stdout:write("Could not queue discovered item. Retrying...\n")
    io.stdout:flush()
    if tries == 10 then
      io.stdout:write("Maximum retries reached for sending discovered item.\n")
      io.stdout:flush()
    else
      os.execute("sleep " .. math.pow(2, tries))
      return discover_item(type_, name, tries + 1)
    end
  end
  abortgrab = true
  return false
end

allowed = function(url, parenturl)
  if string.match(urlparse.unescape(url), "[<>\\%*%$;%^%[%],%(%){}]")
    or string.match(url, "^https?://[^/]*twitter%.com/")
    or string.match(url, "^https?://[^/]*facebook%.com/")
    or string.match(url, "^https?://keskus%.ee/login%.php%?") then
    return false
  end

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

  local match = string.match(url, "^https?://fotoalbum%.ee/photos/([^/%?&]+)$")
  if match then
    discover_item("user", match)
  end

  if string.match(url, "^https?://static[0-9]*%.[^%.]+%.ee/") then
    return true
  end

  for s in string.gmatch(url, "([0-9]+)") do
    if ids[s] then
      return true
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if (downloaded[url] ~= true and addedtolist[url] ~= true)
    and allowed(url, parent["url"]) then
    addedtolist[url] = true
    return true
  end
  
  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  
  downloaded[url] = true

  local function check(urla)
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    url_ = string.match(url_, "^(.-)/?$")
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and allowed(url_, origurl) then
      table.insert(urls, { url=url_ })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
        or string.match(newurl, "^[/\\]")
        or string.match(newurl, "^%./")
        or string.match(newurl, "^[jJ]ava[sS]cript:")
        or string.match(newurl, "^[mM]ail[tT]o:")
        or string.match(newurl, "^vine:")
        or string.match(newurl, "^android%-app:")
        or string.match(newurl, "^ios%-app:")
        or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, newurl))
    end
  end

  if allowed(url, nil) and status_code == 200
    and not string.match(url, "^https?://static[0-9]*%.[^%.]+%.ee/") then
    html = read_file(file)
    if string.match(html, "Kui sul on veel midagi siit vaja") then
      io.stdout:write("Got shutdown message, something went wrong.\n")
      io.stdout:flush()
      abortgrab = true
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  if http_stat["statcode"] ~= 200 and http_stat["statcode"] ~= 302 then
    return false
  end
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()

  local match = string.match(url["url"], "^https?://fotoalbum%.ee/popup%.php%?type=share&pic=([0-9]+)$")
  if match then
    ids[match] = true
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if downloaded[newloc] == true or addedtolist[newloc] == true
      or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end
  
  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end

  if status_code ~= 200 then
    io.stdout:write("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    io.stdout:flush()
    local maxtries = 12
    if not allowed(url["url"], nil) then
      maxtries = 3
    end
    if tries >= maxtries then
      io.stdout:write("I give up...\n")
      io.stdout:flush()
      tries = 0
      if maxtries == 3 then
        return wget.actions.EXIT
      else
        return wget.actions.ABORT
      end
    else
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
      return wget.actions.CONTINUE
    end
  end

  tries = 0

  local sleep_time = 0

  if sleep_time > 0.001 then
    os.execute("sleep " .. sleep_time)
  end

  return wget.actions.NOTHING
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

