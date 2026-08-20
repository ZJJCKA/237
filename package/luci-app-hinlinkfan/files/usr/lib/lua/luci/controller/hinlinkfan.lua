module("luci.controller.hinlinkfan", package.seeall)

function index()
    entry({"admin", "system", "hinlinkfan"}, cbi("/hinlinkfan"),"PWM风扇控制",100)
end
