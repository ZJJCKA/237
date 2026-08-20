#!/bin/sh
# Copyright (C) 2023 Siriling <siriling@qq.com>

#脚本目录
SCRIPT_DIR="/usr/share/modem"

#运行目录
MODEM_RUNDIR="/var/run/modem"
FM350_IPV6_REFRESH_INTERVAL=900

network_probe_ok()
{
    local interface_network="$1" probe_target

    for probe_target in 223.5.5.5 1.1.1.1; do
        if [ -n "${interface_network}" ]; then
            ping -c 1 -W 3 -I "${interface_network}" "${probe_target}" >/dev/null 2>&1 && return 0
        else
            ping -c 1 -W 3 "${probe_target}" >/dev/null 2>&1 && return 0
        fi
    done

    return 1
}

#导入组件工具
source "${SCRIPT_DIR}/modem_debug.sh"

#重设网络接口
# $1:AT串口
# $4:连接定义
# $5:模组序号
reset_network_interface()
{
    local at_port="$1"
    local define_connect="$2"
    local modem_no="$3"

    local interface_name="wwan_5g_${modem_no}"
    local interface_name_ipv6="wwan6_5g_${modem_no}"

    #获取IPv4地址
    local at_command="AT+CGPADDR=${define_connect}"
    local ipv4=$(at ${at_port} ${at_command} | grep "+CGPADDR: " | sed -n '1p' | awk -F',' '{print $2}' | sed 's/"//g')
    #输出日志
    # echo "[$(date +"%Y-%m-%d %H:%M:%S")] Get Modem new IPv4 address : ${ipv4}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

    #获取DNS地址
    local dns=$(fibocom_get_dns ${at_port} ${define_connect})
    local ipv4_dns1=$(echo "${dns}" | jq -r '.dns.ipv4_dns1')
    local ipv4_dns2=$(echo "${dns}" | jq -r '.dns.ipv4_dns2')
    #输出日志
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Get Modem IPv4 DNS1: ${ipv4_dns1}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Get Modem IPv4 DNS2: ${ipv4_dns2}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    
    #比较的网络接口中的IPv4地址
    local ipv4_config=$(uci -q get network.${interface_name}.ipaddr)
    if [ "$ipv4_config" == "$ipv4" ]; then
        #输出日志
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] IPv4 address is the same as in the network interface, skip" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    else
        #输出日志
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Reset network interface ${interface_name}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

        #设置静态地址
	uci set network.wan.metric='2'
	uci set network.wan6.metric='2'
        uci set network.${interface_name}.proto='static'
        uci set network.${interface_name}.ipaddr="${ipv4}"
        uci set network.${interface_name}.netmask='255.255.255.0'
        uci set network.${interface_name}.gateway="${ipv4%.*}.1"
        uci set network.${interface_name}.peerdns='0'
	uci set network.${interface_name}.metric='1'
	uci set network.${interface_name_ipv6}.metric='1'
        uci -q del network.${interface_name}.dns
        uci add_list network.${interface_name}.dns="${ipv4_dns1}"
        uci add_list network.${interface_name}.dns="${ipv4_dns2}"
        uci commit network
        service network reload

        #输出日志
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Reset network interface successful" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    fi
}

#GobiNet拨号
# $1:AT串口
# $2:制造商
# $3:连接定义
gobinet_dial()
{
    local at_port="$1"
    local manufacturer="$2"
    local define_connect="$3"

    #激活
    local at_command="AT+CGACT=1,${define_connect}"
    #打印日志
    dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

    at "${at_port}" "${at_command}"

    #拨号
    local at_command
    if [ "$manufacturer" = "quectel" ]; then
        #移远不走该分支
        at_command='ATI'
    elif [ "$manufacturer" = "fibocom" ]; then
        at_command='AT$QCRMCALL=1,3'
    elif [ "$manufacturer" = "meig" ]; then
        at_command="AT$QCRMCALL=1,1,${define_connect},2,1"
    else
        at_command='ATI'
    fi

    #打印日志
    dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

    at "${at_port}" "${at_command}"
}

#ECM拨号
# $1:AT串口
# $2:制造商
# $3:连接定义
ecm_dial()
{
    local at_port="$1"
    local manufacturer="$2"
    local define_connect="$3"

    #激活
    # local at_command="AT+CGACT=1,${define_connect}"
    # #打印日志
    # dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

    # at "${at_port}" "${at_command}"

    #拨号
    local at_command
    if [ "$manufacturer" = "quectel" ]; then
        at_command="AT+QNETDEVCTL=${define_connect},3,1"
    elif [ "$manufacturer" = "fibocom" ]; then
        at_command="AT+GTRNDIS=1,${define_connect}"
    elif [ "$manufacturer" = "meig" ]; then
        at_command="AT^NDISDUP=${define_connect},1"
    elif [ "$manufacturer" = "huawei" ]; then
        at_command="AT^NDISDUP=${define_connect},1"
    elif [ "$manufacturer" = "tdtech" ]; then
        at_command="AT^NDISDUP=${define_connect},1"
    else
        at_command='ATI'
    fi

    #打印日志
    dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

    at "${at_port}" "${at_command}"

    sleep 2s
}

#RNDIS拨号
# $1:AT串口
# $2:制造商
# $3:平台
# $4:连接定义
# $5:模组序号
rndis_dial()
{
    local at_port="$1"
    local manufacturer="$2"
    local platform="$3"
    local define_connect="$4"
    local modem_no="$5"

    #手动拨号（广和通FM350-GL）
    if [ "$manufacturer" = "fibocom" ] && [ "$platform" = "mediatek" ]; then
        sleep 3s
	local at_command="AT+COPS?"
        isp=$(at ${at_port} ${at_command} | grep "+COPS" | awk -F'"' '{print $2}' | tr -d '\r\n' | xargs)
        if [[ "$isp" == "4E2D56FD8054901A" ]]; then
        isp="CHN-UNICOM"
        fi

	if [[ "$isp" == "CHN-CMCC" || "$isp" == "CMCC" || "$isp" == "46000" || "$isp" == "CHINA MOBILE"]]; then
    	at_command="AT+CGDCONT=${define_connect},\"IPV4V6\",\"cbnet\""
    	at "$at_port" "$at_command"
	echo "matching ISP: [$isp]" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
	elif [[ "$isp" == "CHN-UNICOM" || "$isp" == "UNICOM" || "$isp" == "46001" ]]; then
    	at_command="AT+CGDCONT=${define_connect},\"IPV4V6\",\"3gnet\""
    	at "$at_port" "$at_command"
	echo "matching ISP: [$isp]" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
	elif [[ "$isp" == "CHN-CT" || "$isp" == "CT" || "$isp" == "46011"  || "$isp" == "CHINA TELECOM"]]; then
    	at_command="AT+CGDCONT=${define_connect},\"IPV4V6\",\"ctnet\""
    	at "$at_port" "$at_command"
	echo "matching ISP: [$isp]" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
	else
    	echo "No matching ISP: [$isp]" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
	at_command="AT+CGDCONT=${define_connect},\"IPV4V6\",\"cbnet\""
        at "$at_port" "$at_command"
        echo "matching ISP: [$isp]" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
	fi
	local at_command="AT+CGACT=1,${define_connect}"
        #打印日志
        dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
        #激活并拨号
	sleep 3s
        at "${at_port}" "${at_command}"
    else
        #拨号
        ecm_dial "${at_port}" "${manufacturer}" "${define_connect}"
    fi
}

#Modem Manager拨号
# $1:接口名称
# $2:连接定义
modemmanager_dial()
{
    local interface_name="$1"
    local define_connect="$2"

    # #激活
    # local at_command="AT+CGACT=1,${define_connect}"
    # #打印日志
    # dial_log "${at_command}" "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    # at "${at_port}" "${at_command}"

    #启动网络接口
    ifup "${interface_name}";
}

#检查模组网络连接
# $1:配置ID
# $2:模组序号
# $3:拨号模式
modem_network_task()
{
    local config_id="$1"
    local modem_no="$2"
    local mode="$3"

    #获取AT串口，制造商，平台，连接定义，接口名称
    local at_port=$(uci -q get modem.modem${modem_no}.at_port)
    local manufacturer=$(uci -q get modem.modem${modem_no}.manufacturer)
    local platform=$(uci -q get modem.modem${modem_no}.platform)
    local define_connect=$(uci -q get modem.modem${modem_no}.define_connect)
    local interface_name="wwan_5g_${modem_no}"
    local interface_name_ipv6="wwan6_5g_${modem_no}"
    local interface_network=$(uci -q get modem.modem${modem_no}.network_interface)
    #AT串口未获取到重新获取（解决模组还在识别中，就已经开始拨号的问题）
    while [ -z "$manufacturer" ] || [ "$manufacturer" = "unknown" ]; do
        at_port=$(uci -q get modem.modem${modem_no}.at_port)
        manufacturer=$(uci -q get modem.modem${modem_no}.manufacturer)
        platform=$(uci -q get modem.modem${modem_no}.platform)
        define_connect=$(uci -q get modem.modem${modem_no}.define_connect)
        sleep 1s
    done

    #重载配置（解决AT命令发不出去的问题）
    # service modem reload

    #IPv4地址缓存
    local ipv4_cache
    local probe_failures=0
    local probe_alerted=0
    local last_fm350_ipv6_refresh=0

    #输出日志
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Start network task" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
    while true; do
        # USB modems can re-enumerate after a radio reset. Refresh dynamic
        # paths so all modem types avoid retaining stale port/interface names.
        at_port=$(uci -q get modem.modem${modem_no}.at_port)
        manufacturer=$(uci -q get modem.modem${modem_no}.manufacturer | tr 'A-Z' 'a-z')
        modem_name=$(uci -q get modem.modem${modem_no}.name | tr 'A-Z' 'a-z')
        interface_network=$(uci -q get modem.modem${modem_no}.network_interface)
        #全局
        local enable_dial=$(uci -q get modem.@global[0].enable_dial)
        if [ "$enable_dial" != "1" ]; then
            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] The dialing configuration has been disabled, this network task quit" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            break
        fi
        #单个模组
        enable=$(uci -q get modem.${config_id}.enable)
        if [ "$enable" != "1" ]; then
            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] The modem has disabled dialing, this network task quit" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            break
        fi

        # A single public resolver can rate-limit ICMP while the modem session
        # is healthy. Check two targets and require three failed rounds.
	if network_probe_ok "${interface_network}"; then
            if [ "${probe_alerted}" -eq 1 ]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Network reachability restored" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            fi
            probe_failures=0
            probe_alerted=0
        else
            probe_failures=$((probe_failures + 1))
            if [ "${probe_failures}" -lt 3 ]; then
                sleep 5s
                continue
            fi
            if [ "${probe_alerted}" -eq 0 ]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Network reachability failed for 3 consecutive multi-target probes" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
                probe_alerted=1
            fi
	local at_command="AT+CGPADDR=${define_connect}"
        local ipv4=$(at ${at_port} ${at_command} | grep "+CGPADDR: " | sed -n '1p' | awk -F',' '{print $2}' | sed 's/"//g')

        if [ -z "$ipv4" ]; then
            [ "$mode" = "modemmanager" ] && {
                #拨号工具为modemmanager时，不需要重新设置连接定义
                sleep 5s
                continue
            }
            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Unable to get IPv4 address" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Redefine connect to ${define_connect}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            service modem reload

            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Modem dial" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            #拨号（针对获取IPv4返回为空的模组）
            case "$mode" in
                "gobinet") gobinet_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
                "ecm") ecm_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
                "rndis") rndis_dial "${at_port}" "${manufacturer}" "${platform}" "${define_connect}" "${modem_no}" ;;
                "modemmanager") modemmanager_dial "${interface_name}" "${define_connect}" ;;
                *) ecm_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
            esac
        elif [[ "$ipv4" = *"0.0.0.0"* ]]; then

            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Modem${modem_no} current IPv4 address : ${ipv4}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Modem dial" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            #拨号
            case "$mode" in
                "gobinet") gobinet_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
                "ecm") ecm_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
                "rndis") rndis_dial "${at_port}" "${manufacturer}" "${platform}" "${define_connect}" "${modem_no}" ;;
                "modemmanager") modemmanager_dial "${interface_name}" "${define_connect}" ;;
                *) ecm_dial "${at_port}" "${manufacturer}" "${define_connect}" ;;
            esac
            
        elif [ "$ipv4" != "$ipv4_cache" ]; then

            #第一次缓存IP为空时不输出日志
            [ -n "$ipv4_cache" ] && {
                #输出日志
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Modem${modem_no} IPv4 address has changed" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"
            }

            #输出日志
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Modem${modem_no} current IPv4 address : ${ipv4}" >> "${MODEM_RUNDIR}/modem${modem_no}_dial.cache"

            #缓存当前IP
            ipv4_cache="${ipv4}"

            #重新设置网络接口（广和通FM350-GL）
            if [ "$manufacturer" = "fibocom" ] && [ "$platform" = "mediatek" ]; then
                reset_network_interface "${at_port}" "${define_connect}" "${modem_no}"
                sleep 3s
            fi

            [ "$mode" != "modemmanager" ] && {
                #重新启动网络接口
                ifup "${interface_name}"
                ifup "${interface_name_ipv6}"
            }
	    /etc/init.d/firewall restart
        fi
	fi

        # FM350 RNDIS can lose IPv6 after a long session. Refresh discovery
        # only for Fibocom FM350, leaving every other modem protocol untouched.
        case "${mode}:${manufacturer}:${modem_name}" in
            rndis:fibocom:*fm350*)
                if [ -n "${interface_network}" ]; then
                    now_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
                    case "${now_uptime}" in
                        ''|*[!0-9]*) now_uptime=0 ;;
                    esac
                    if [ "${last_fm350_ipv6_refresh}" -eq 0 ] || \
                        [ $((now_uptime - last_fm350_ipv6_refresh)) -ge "${FM350_IPV6_REFRESH_INTERVAL}" ]; then
                        rdisc6 "${interface_network}" >/dev/null 2>&1 &
                        ndisc6 fe80::1 "${interface_network}" >/dev/null 2>&1 &
                        last_fm350_ipv6_refresh="${now_uptime}"
                    fi
                fi
                ;;
        esac
        sleep 5s
    done
}

modem_network_task "$1" "$2" "$3"
