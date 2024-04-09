--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core     = require("apisix.core")
local log_util = require("apisix.utils.log-util")
local producer = require ("resty.kafka.producer")
local bp_manager_mod = require("apisix.utils.batch-processor-manager")
local plugin = require("apisix.plugin")

local math     = math
local pairs    = pairs
local type     = type
local plugin_name = "kafka-body-sender"
local batch_processor_manager = bp_manager_mod.new("kafka body sender")
local ngx = ngx
local io = io
local json_decode = core.json.decode

local lrucache = core.lrucache.new({
    type = "plugin",
})

local schema = {
    type = "object",
    properties = {
        -- deprecated, use "brokers" instead
        broker_list = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                [".*"] = {
                    description = "the port of kafka broker",
                    type = "integer",
                    minimum = 1,
                    maximum = 65535,
                },
            },
        },
        brokers = {
            type = "array",
            minItems = 1,
            items = {
                type = "object",
                properties = {
                    host = {
                        type = "string",
                        description = "the host of kafka broker",
                    },
                    port = {
                        type = "integer",
                        minimum = 1,
                        maximum = 65535,
                        description = "the port of kafka broker",
                    },
                    sasl_config = {
                        type = "object",
                        description = "sasl config",
                        properties = {
                            mechanism = {
                                type = "string",
                                default = "PLAIN",
                                enum = {"PLAIN"},
                            },
                            user = { type = "string", description = "user" },
                            password =  { type = "string", description = "password" },
                        },
                        required = {"user", "password"},
                    },
                },
                required = {"host", "port"},
            },
            uniqueItems = true,
        },
        kafka_topic = {type = "string"},
        producer_type = {
            type = "string",
            default = "async",
            enum = {"async", "sync"},
        },
        required_acks = {
            type = "integer",
            default = 1,
            enum = { 0, 1, -1 },
        },
        key = {type = "string"},
        timeout = {type = "integer", minimum = 1, default = 3},
        include_req_body = {type = "boolean", default = false},
        include_req_body_expr = {
            type = "array",
            minItems = 1,
            items = {
                type = "array"
            }
        },
        valid_req_json = {type = "boolean", default = false},
        include_resp_body = {type = "boolean", default = false},
        include_resp_body_expr = {
            type = "array",
            minItems = 1,
            items = {
                type = "array"
            }
        },
        -- in lua-resty-kafka, cluster_name is defined as number
        -- see https://github.com/doujiang24/lua-resty-kafka#new-1
        cluster_name = {type = "integer", minimum = 1, default = 1},
        -- config for lua-resty-kafka, default value is same as lua-resty-kafka
        producer_batch_num = {type = "integer", minimum = 1, default = 1},
        producer_batch_size = {type = "integer", minimum = 0, default = 1},
        producer_max_buffering = {type = "integer", minimum = 1, default = 50000},
        producer_time_linger = {type = "integer", minimum = 1, default = 1},
    },
    oneOf = {
        { required = {"broker_list", "kafka_topic"},},
        { required = {"brokers", "kafka_topic"},},
    }
}

local metadata_schema = {
    type = "object",
    properties = {
        log_format = log_util.metadata_schema_log_format,
    },
}

local _M = {
    version = 0.1,
    priority = 403,
    name = plugin_name,
    schema = batch_processor_manager:wrap_schema(schema),
    metadata_schema = metadata_schema,
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, err
    end
    return log_util.check_log_schema(conf)
end

local function get_file(file_name)
    local f = assert(io.open(file_name, 'r'))
    local str = f:read("*all")
    f:close()
    return str
end

local function local_json_decode(jsonStr)
    local succ,val,err  = pcall(json_decode, jsonStr)
    if  succ == false or type(val) ~= "table" then
        return nil, err
    else
        return val, err
    end
end


local function get_post_json_data(valid_json)
  local out = 'ok'
    if "POST" ~= ngx.var.request_method   then
        out =   '[POST need]'
        ngx.log(ngx.CRIT,out)
        return nil, out
    end
     ngx.req.read_body()

    local post_data = ngx.req.get_body_data()
    if post_data == nil then
        out =('[args is null]')
        -- ngx.log(ngx.CRIT,out)

        local file_name = ngx.req.get_body_file()
        if file_name then
            out = '[get from file]'
            -- ngx.log(ngx.CRIT,out, file_name)
            post_data = get_file(file_name)
        else
            out = "body file is empty"
            ngx.log(ngx.ERR,'body_file empty')
            return nil, out
        end
    end
    if valid_json then
        local entry, err = local_json_decode(post_data)
        if not entry then
            -- ngx.log(ngx.CRIT,'local_json_decode failed', err, "[", post_data, "]")
            return nil, 'json fail'
        end

        return entry, out
    end
    return post_data, out
end

function _M.access(conf, ctx)
    local post_data, err = get_post_json_data(conf.valid_req_json)
    if not post_data then
        ngx.status = ngx.HTTP_FORBIDDEN

        ngx.say(core.json.encode({ error = "Forbidden", message = err}))

        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
 
    ctx.entry = post_data
    -- ngx.log(ngx.CRIT, 'build entry for kafka', core.json.encode(conf.brokers) )
    ngx.say(core.json.encode({status = 'ok','message' = err}))
    return ngx.exit(ngx.HTTP_OK)
end

local function get_partition_id(prod, topic, log_message)
    if prod.async then
        local ringbuffer = prod.ringbuffer
        for i = 1, ringbuffer.size, 3 do
            if ringbuffer.queue[i] == topic and
                ringbuffer.queue[i+2] == log_message then
                return math.floor(i / 3)
            end
        end
        core.log.crit("current topic in ringbuffer has no message")
        return nil
    end

    -- sync mode
    local sendbuffer = prod.sendbuffer
    if not sendbuffer.topics[topic] then
        core.log.crit("current topic in sendbuffer has no message")
        return nil
    end
    for i, message in pairs(sendbuffer.topics[topic]) do
        if log_message == message.queue[2] then
            return i
        end
    end
end


local function create_producer(broker_list, broker_config, cluster_name)
    core.log.crit("create new kafka producer instance")
    return producer:new(broker_list, broker_config, cluster_name)
end


local function send_kafka_data(conf, log_message, prod)
    local ok, err = prod:send(conf.kafka_topic, conf.key, log_message)

    if not ok then
        return false, "failed to send data to Kafka topic: " .. err ..
                ", brokers: " .. core.json.encode(conf.broker_list)
    end

    return true
end
 
function _M.log(conf, ctx)
    local entry = ctx.entry

    if batch_processor_manager:add_entry(conf, entry) then
        return
    end

    -- reuse producer via lrucache to avoid unbalanced partitions of messages in kafka
    local broker_list = core.table.clone(conf.brokers or {})
    local broker_config = {}

    if conf.broker_list then
        for host, port in pairs(conf.broker_list) do
            local broker = {
                host = host,
                port = port
            }
            core.table.insert(broker_list, broker)
        end
    end

    broker_config["request_timeout"] = conf.timeout * 1000
    broker_config["producer_type"] = conf.producer_type
    broker_config["required_acks"] = conf.required_acks
    broker_config["batch_num"] = conf.producer_batch_num
    broker_config["batch_size"] = conf.producer_batch_size
    broker_config["max_buffering"] = conf.producer_max_buffering
    broker_config["flush_time"] = conf.producer_time_linger * 1000

    local prod, err = core.lrucache.plugin_ctx(lrucache, ctx, nil, create_producer,
                                               broker_list, broker_config, conf.cluster_name)
    -- core.log.crit("kafka cluster name ", conf.cluster_name, ", broker_list[1] port ", prod.client.broker_list[1].port)
    if err then
        return nil, "failed to identify the broker specified: " .. err
    end

    local post_data = entry
    if conf.valid_req_json then
        post_data = core.json.encode(entry)
    end

    local ok,err = send_kafka_data(conf, post_data, prod)

    if not ok then
        ngx.log(ngx.ERR, 'send data to kafka failed',post_data)
    end
end


return _M
