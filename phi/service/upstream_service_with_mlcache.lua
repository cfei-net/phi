--
-- Created by IntelliJ IDEA.
-- User: yangyang.zhang
-- Date: 2018/2/24
-- Time: 15:13
-- 查询db和多级缓存
-- L1:Worker级别的LRU CACHE
-- L2:共享内存SHARED_DICT
-- L3:Redis,作为回源DB使用
--
local ngx_upstream = require "ngx.upstream"
local CONST = require "core.constants"
local mlcache = require "resty.mlcache"
local pretty_write = require("pl.pretty").write

local balancer_wrapper = require "core.balancer.balancer_wrapper"

local get_upstreams = ngx_upstream.get_upstreams
local set_peer_down = ngx_upstream.set_peer_down
local worker_pid = ngx.worker.pid
local tonumber = tonumber
local ipairs = ipairs
local type = type
local gsub = string.gsub
local pairs = pairs
local getn = table.getn
local insert = table.insert
local NIL_VALUE = { notExists = true }

local _ok, new_tab = pcall(require, "table.new")
if not _ok or type(new_tab) ~= "function" then
    new_tab = function()
        return {}
    end
end

local re_match = ngx.re.match

local ERR = ngx.ERR
local DEBUG = ngx.DEBUG
local NOTICE = ngx.NOTICE
local LOGGER = ngx.log

local EVENTS = CONST.EVENT_DEFINITION.UPSTREAM_EVENTS
local PHI_UPSTREAM_DICT_NAME = CONST.DICTS.PHI_UPSTREAM
local PHI_EVENTS_DICT_NAME = CONST.DICTS.PHI_EVENTS

local SHARED_DICT = ngx.shared[PHI_UPSTREAM_DICT_NAME]

local _M = {}
function _M:init()
    -- 加载配置文件中的upstream信息，所有的upstream信息使用stable占位
    local us = get_upstreams()
    for _, u in ipairs(us) do
        self.cache:set(u, nil, "stable")
    end
end

function _M:init_worker(observer)
    self.observer = observer
    -- 关注dynamic upstream的更新操作
    observer.register(function(data, event, source, pid)
        if worker_pid() == pid then
            LOGGER(NOTICE, "do not process the event send from self")
        else
            LOGGER(DEBUG, "received event; source=", source,
                    ", event=", event,
                    ", data=", pretty_write(data),
                    ", from process ", pid)
            -- server增删情况下，重建balancer
            self.cache:update()
            self:getUpstreamBalancer(data)
        end
    end, EVENTS.DYNAMIC_UPS_SOURCE)
    -- 关注配置中的peer的启停
    observer.register(function(data, event, source, pid)
        LOGGER(DEBUG, "received event; source=", source,
                ", event=", event,
                ", data=", pretty_write(data),
                ", from process ", pid)
        if worker_pid() == pid and type(data[4]) ~= "boolean" then
            LOGGER(NOTICE, "do not process the event send from self")
        else
            if type(data[4]) == "boolean" then
                set_peer_down(data[1], data[2], data[3], data[4])
            else
                self:getUpstreamBalancer(data[1]):set(data[2], data[3])
            end
        end
    end, EVENTS.SOURCE)
end

-- 需要通知其他worker进程peer状态改变
function _M:peerStateChangeEvent(upstreamName, isBackup, peerId, down)
    local event = down and EVENTS.PEER_DOWN or EVENTS.PEER_UP
    self.observer.post(EVENTS.SOURCE, event, { upstreamName, isBackup, peerId, down })
end

-- 需要通知其他worker进程更新缓存中的dynamic_server信息
function _M:dynamicUpsChangeEvent(upstreamName)
    local event = EVENTS.DYNAMIC_UPS_UPDATE or EVENTS.DYNAMIC_UPS_DEL
    self.observer.post(EVENTS.DYNAMIC_UPS_SOURCE, event, upstreamName)
end

-- 获取所有运行时信息,这个方法最多会获取1024条信息
function _M:getAllRuntimeInfo()
    local upsNames = SHARED_DICT:get_keys()
    local result = new_tab(0, getn(upsNames))
    for _, name in ipairs(upsNames) do
        if self:getUpstreamBalancer(name) ~= "ip:port" then
            name = gsub(name, "dynamic_ups_cache", "")
            local info = self:getUpstreamServers(name)
            result[name] = info
        end
    end
    return result
end

-- 获取所有运行时信息,这个方法最多会获取1024条信息
function _M:getAllUpsInfo()
    local result = {}
    local upsNames = SHARED_DICT:get_keys()
    for _, name in ipairs(upsNames) do
        if self:getUpstreamBalancer(name) ~= "ip:port" then
            name = gsub(name, "dynamic_ups_cache", "")
            local info = self:getUpstreamServers(name)
            result[name] = info
        end
    end
    local dynamicUps, err = self.dao:getAllUpstreams(0, 1024)
    if not err then
        for k, v in pairs(dynamicUps.data) do
            if not result[k] then
                result[k] = v
            end
        end
    else
        LOGGER(NOTICE, "find upstream servers error : ", err)
    end
    return result
end

-- 关闭指定的peer，暂时不参与负载均衡
function _M:setPeerDown(upstreamName, peerId, down)
    -- 查询L2
    local isBackup
    local _, err, upstreamInfo = self.cache:peek(upstreamName)
    local ok
    if upstreamInfo == "stable" then
        local serversInfos = self:getUpstreamServers(upstreamName)
        for _, s in ipairs(serversInfos) do
            if s.name == peerId then
                peerId = s.id
                isBackup = s.backup
            end
        end
        if isBackup == nil then
            err = "错误的server name：" .. peerId
            LOGGER(ERR, err)
        else
            ok, err = ngx_upstream.set_peer_down(upstreamName, isBackup, peerId, down)
            if ok then
                self:peerStateChangeEvent(upstreamName, isBackup, peerId, down)
            end
        end
    else
        if not upstreamInfo then
            -- 查询DB
            upstreamInfo, err = self.dao:getUpstreamServers(upstreamName)
            if err or upstreamInfo == nil then
                err = "查询upstream出错！可能是不存在upstreamName:" .. upstreamName
                LOGGER(ERR, err)
                return ok, err
            end
        end
        -- 更新db
        local weight
        weight, err = self.dao:downUpstreamServer(upstreamName, peerId, down)
        if not err then
            if down then
                weight = 0

            end
            local balancer = self:getUpstreamBalancer(upstreamName)
            if balancer and type(balancer.set) == "function" then
                --balancer:set(peerId, weight)
                local ok, res = pcall(balancer.set, balancer, peerId, weight)
                if not ok then
                    self.dao:downUpstreamServer(upstreamName, peerId, false)
                    self.cache:delete(upstreamName)
                    self:dynamicUpsChangeEvent(upstreamName)
                    return nil, "empty upstream nodes"
                end
                self:peerStateChangeEvent(upstreamName, peerId, weight)
            else
                self.cache:delete(upstreamName)
                self:dynamicUpsChangeEvent(upstreamName)
            end
            ok = true
        end
    end
    return ok, err
end

-- 刷新缓存
function _M:refreshCache(upstreamName)
    local ok
    local res, err = self.dao:getUpstreamServers(upstreamName)
    if err then
        LOGGER(ERR, "could not retrieve upstream servers:", err)
    elseif res == nil then
        LOGGER(NOTICE, "could not find upstream servers")
        ok, err = self.cache:set(upstreamName, nil, NIL_VALUE)
        if ok then
            self:dynamicUpsChangeEvent(upstreamName)
        else
            LOGGER(ERR, "could not update cache, upstreamName:", upstreamName)
        end
    else
        ok, err = self.cache:set(upstreamName, nil, res)
        -- 通知其它worker更新缓存
        if ok then
            self:dynamicUpsChangeEvent(upstreamName)
        else
            LOGGER(ERR, "could not update cache, upstreamName:", upstreamName)
        end
    end
    return ok, err
end

-- 动态添加upstream中的server
function _M:addUpstreamServers(upstream, servers)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:addUpstreamServers(upstream, servers)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                ok, err = self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 添加或者更新upstream
function _M:addOrUpdateUps(upstream, servers)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:addOrUpdateUps(upstream, servers)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                ok, err = self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 动态添加upstream中的server
function _M:delUpstreamServers(upstream, servers)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:delUpstreamServers(upstream, servers)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                ok, err = self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 动态添加upstream中的server
function _M:delUpstream(upstream)
    -- 查询
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local ok
    if not err then
        if upstreamInfo == "stable" then
            err = "暂不支持对配置文件中的upstream进行编辑！"
        else
            ok, err = self.dao:delUpstream(upstream)
            if ok then
                --通知其它worker进行更新缓存,并且重建balancer
                ok, err = self:refreshCache(upstream)
            end
        end
    else
        LOGGER(ERR, "查询upstream信息出现错误，err:", err)
    end
    return ok, err
end

-- 查询upstream中的所有server信息
function _M:getUpstreamServers(upstream)
    local _, err, upstreamInfo = self.cache:peek(upstream)
    local data
    if upstreamInfo == "stable" then
        local upsPrimaryServers = ngx_upstream.get_primary_peers(upstream)
        local upsBackupServers = ngx_upstream.get_backup_peers(upstream)
        data = new_tab(#upsPrimaryServers + #upsPrimaryServers, 0)
        for _, s in ipairs(upsPrimaryServers) do
            s.backup = false
            insert(data, s)
        end
        for _, s in ipairs(upsBackupServers) do
            s.backup = true
            insert(data, s)
        end
    elseif type(upstreamInfo) == "table" then
        data = new_tab(0, 3)
        data.servers = new_tab(50, 0)
        local tmp
        tmp, err = self.dao:getUpstreamServers(upstream)
        if tmp then
            for k, v in pairs(tmp) do
                if k == "strategy" then
                    data.strategy = v
                elseif k == "mapper" then
                    data.mapper = v
                else
                    insert(data.servers, { name = k, weight = tonumber(v.weight) or 1, down = v.down or false })
                end
            end
        end
    end
    if not err and not data then
        err = "不存在的upstream！"
    end
    return data, err
end

local function newBalancer(res)
    if res == "stable" or res == "ip:port" then
        return res
    end
    return balancer_wrapper:new(res)
end

local function getFromDb(self, upstream)
    local res, err = self.dao:getUpstreamServers(upstream)
    if res then
        return res
    else
        -- 简单判断一下是否属于IP
        local m = re_match(upstream, "^(\\d{1,3}\\.){3}\\d{1,3}\\:\\d{1,5}$", "jo")
        if m then
            return "ip:port"
        end
    end
    if err then
        -- 查询出现错误，10秒内不再查询
        LOGGER(ERR, "could not retrieve upstream servers:", err)
    end
    return NIL_VALUE, nil, 10
end

-- 获取upstream信息
function _M:getUpstreamBalancer(upstream)
    local result, err = self.cache:get(upstream, nil, getFromDb, self, upstream)
    return result, err
end

local class = {}

function class:new(ref, config)
    -- new函数我会在init阶段调用，我在这里就初始化cache，并且在init函数中load部分数据，worker进程会fork这部分内存，相当于缓存的预热
    local cache, err = mlcache.new("dynamic_ups_cache", PHI_UPSTREAM_DICT_NAME, {
        lru_size = config.router_lrucache_size or 1000, -- L1缓存大小，默认取1000
        ttl = 0, -- 缓存失效时间
        neg_ttl = 0, -- 未命中缓存失效时间
        resty_lock_opts = {
            -- 回源DB的锁配置
            exptime = 10, -- 锁失效时间
            timeout = 5 -- 获取锁超时时间
        },
        ipc_shm = PHI_EVENTS_DICT_NAME, -- 通知其他worker的事件总线
        l1_serializer = newBalancer -- 数据序列化
    })
    if err then
        error("could not create mlcache for dynamic upstream cache ! err :" .. err)
    end
    return setmetatable({ dao = ref, cache = cache }, { __index = _M })
end

return class