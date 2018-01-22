--
-- Created by IntelliJ IDEA.
-- User: yangyang.zhang
-- Date: 2018/1/6
-- Time: 16:33
-- 用来做路由控制，根据指定规则进行访问控制：如灰度发布等.
--[[
    一个标准的路由表规则数据结构,多级路由的情况下,会按照顺序依次寻找符合条件的路由目标：
    {
        "default":"",
        "policies":[
         {
            "tag":"uid",
            "mapper":"uri_args",//枚举值 header uri_args
            "policy":"range_policy",//枚举值 range_policy
            //规则表
            "routerTable":{
                "upstream9999":[100,1000],
                "upstream9999":[1001,2000],
                "upstream9999":[2001,2100]
            }
         }
        ]
    }
--]]

local utils = require "utils"
local lrucache = require "resty.lrucache"
local cjson = require "cjson.safe"
local LOGGER = ngx.log
local DEBUG = ngx.DEBUG
local ERR = ngx.ERR
local ALERT = ngx.ALERT
local var = ngx.var

local class = {}
local _M = {}

function class:new(config)
    local c, err = lrucache.new(config.router_lrucache_size)
    _M.cache = c
    if not c then
        return error("failed to create the cache: " .. (err or "unknown"))
    end
    return setmetatable({}, { __index = _M })
end

function _M.before()
end

-- 主要:根据host查找路由表，根据对应规则对本次请求中的backend变量进行赋值，达到路由到指定upstream的目的
function _M:access()
    local hostkey = utils.getHost();
    if hostkey then
        local rules, err = self.cache:get(hostkey)
        if not rules then
            LOGGER(DEBUG, "缓存未命中，hostkey：", hostkey)

            rules = PHI.dao:selectRouterPolicy(hostkey)
            -- 放入缓存
            if not err then
                -- 路由规则排序
                LOGGER(DEBUG, "加入缓存，hostkey：", hostkey)
                table.sort(rules.policies, function(r1, r2) return r1.order < r2.order end)
                self.cache:set(hostkey, rules)
            else
                LOGGER(ERR, "路由规则计算出现错误，err：", err)
            end
        else
            LOGGER(DEBUG, "缓存命中，hostkey：", hostkey)
        end
        if not err and rules and type(rules) == "table" then
            -- 先取默认值
            local result = rules.default

            -- 计算路由结果
            for _, t in pairs(rules.policies) do
                local tag = PHI.mapper_holder:map(t.mapper, t.tag)
                local upstream, err = PHI.policy_holder:calculate(t.policy, tag, t.routerTable)
                if err then
                    LOGGER(ERR, "路由规则计算出现错误，err：", err)
                elseif upstream then
                    result = upstream
                    break
                end
            end

            var.backend = result
            LOGGER(DEBUG, "请求将被路由到，upstream：", result)
        else
            LOGGER(ERR, err or ("路由规则格式错误，err：" .. cjson.encode(rules or "nil")))
        end
    else
        LOGGER(ALERT, "hostkey为nil，无法执行路由操作")
    end
end

function _M.after()
end

return class