local dispatcher = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
m = Map("hinlinkfan", translate("PWM风扇控制"))
m:chain("luci")

--读取配置信息的global片段
s = m:section(TypedSection, "global") 
s.anonymous = true
s.addremove = false

--创建两个表页面
s:tab("gereral", "基础配置",translate(""))

r_enable = s:taboption("gereral",Flag, "enable", translate("启用风扇控制"),translate("PWM风扇控制"))
r_enable.disabled = 0
server_ip = s:taboption("gereral",Value, "on_temp", translate("启动风扇时CPU温度"))
server_ip.default = "50"
server_ip.datatype = "string"
secureId = s:taboption("gereral",Value, "off_temp", translate("关闭风扇时CPU温度"))
secureId.default = "45"
secureId.datatype = "string"


local event_handlers = {}
function register_event(event_name, handler)
  event_handlers[event_name] = handler
end
function trigger_event(event_name,...)
  if event_handlers[event_name] then
    event_handlers[event_name](...)
  end
end


m.on_after_commit = function(self)
    luci.util = require "luci.util"
    -- luci.util.exec("/etc/init.d/netstateinit stop")

end

m.on_before_apply = function(self)
    luci.util = require "luci.util"
    -- luci.util.exec("/etc/init.d/netstateinit start")
end

function m.on_commit(self)
  -- 保存配置代码
  -- 触发保存后事件
  trigger_event("after_config_save", self)
end

-- 注册事件处理函数
register_event("after_config_save", function(self)
  luci.util.exec("/etc/init.d/hinlinkfaninit restart")
end)

return m



