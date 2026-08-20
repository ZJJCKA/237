#!/bin/sh
# Copyright (C) 2023 Siriling <siriling@qq.com>

#脚本目录
SCRIPT_DIR="/usr/share/modem"

#预设
tw_presets()
{
    #设置IPv6地址格式
	at_command='AT+CGPIAF=1,0,0,0'
	sh "${SCRIPT_DIR}/modem_at.sh" "$at_port" "$at_command"
}

#获取DNS
# $1:AT串口
# $2:连接定义
tw_get_dns()
{
    local at_port="$1"
    local define_connect="$2"

    [ -z "$define_connect" ] && {
        define_connect="1"
    }

    local public_dns1_ipv4="223.5.5.5"
    local public_dns2_ipv4="119.29.29.29"
    local public_dns1_ipv6="2400:3200::1" #下一代互联网北京研究中心：240C::6666，阿里：2400:3200::1，腾讯：2402:4e00::
    local public_dns2_ipv6="2402:4e00::"

    #获取DNS地址
    at_command="AT+TDHCP"
    # local response=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "${define_connect}: IPv4" | grep -E '[0-9]+.[0-9]+.[0-9]+.[0-9]+')
    local response=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "${define_connect}: IPv4")

    local ipv4_dns1=$(echo "${response}" | awk -F',' '{print $2}' | awk -F'"' '{print $2}')
    [ -z "$ipv4_dns1" ] && {
        ipv4_dns1="${public_dns1_ipv4}"
    }

    local ipv4_dns2=$(echo "${response}" | awk -F',' '{print $3}' | awk -F'"' '{print $2}')
    [ -z "$ipv4_dns2" ] && {
        ipv4_dns2="${public_dns2_ipv4}"
    }

    local ipv6_dns1=$(echo "${response}" | awk -F',' '{print $5}' | awk -F'"' '{print $2}')
    [ -z "$ipv6_dns1" ] && {
        ipv6_dns1="${public_dns1_ipv6}"
    }

    local ipv6_dns2=$(echo "${response}" | awk -F',' '{print $6}' | awk -F'"' '{print $2}')
    [ -z "$ipv6_dns2" ] && {
        ipv6_dns2="${public_dns2_ipv6}"
    }

    dns="{
        \"dns\":{
            \"ipv4_dns1\":\"$ipv4_dns1\",
            \"ipv4_dns2\":\"$ipv4_dns2\",
            \"ipv6_dns1\":\"$ipv6_dns1\",
            \"ipv6_dns2\":\"$ipv6_dns2\"
	    }
    }"

    echo "$dns"
}

#获取拨号模式
# $1:AT串口
# $2:平台
tw_get_mode()
{
    local at_port="$1"
    local platform="$2"

    at_command="AT+TPVID?"
    local mode_num=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+TPVID:" | awk -F',' '{print $2}' | sed 's/\r//g')

    if [ -z "$mode_num" ]; then
        echo "unknown"
        return
    fi

    #获取芯片平台
	if [ -z "$platform" ]; then
		local modem_number=$(uci -q get modem.@global[0].modem_number)
        for i in $(seq 0 $((modem_number-1))); do
            local at_port_tmp=$(uci -q get modem.modem$i.at_port)
            if [ "$at_port" = "$at_port_tmp" ]; then
                platform=$(uci -q get modem.modem$i.platform)
                break
            fi
        done
	fi

    local mode
    case "$platform" in
        "qualcomm")
            case "$mode_num" in
                "2004"|"2009") mode="qmi" ;;
                "2008") mode="ecm" ;;
                "2001") mode="rndis" ;;
                "2007"|"2010"|"2015") mode="mbim" ;;
                *) mode="$mode_num" ;;
            esac
        ;;
        *)
            mode="$mode_num"
        ;;
    esac
    echo "${mode}"
}

#设置拨号模式
# $1:AT串口
# $2:拨号模式配置
tw_set_mode()
{
    local at_port="$1"
    local mode_config="$2"

    #获取芯片平台
    local platform
    local modem_number=$(uci -q get modem.@global[0].modem_number)
    for i in $(seq 0 $((modem_number-1))); do
        local at_port_tmp=$(uci -q get modem.modem$i.at_port)
        if [ "$at_port" = "$at_port_tmp" ]; then
            platform=$(uci -q get modem.modem$i.platform)
            break
        fi
    done

    #获取拨号模式配置
    local mode_num
    case "$platform" in
        "qualcomm")
            case "$mode_config" in
                "qmi") mode_num="2004" ;;
                "ecm") mode_num="2008" ;;
                "rndis") mode_num="2001" ;;
                "mbim") mode_num="2007" ;;
                *) mode_num="0" ;;
            esac
        ;;
        *)
            mode_num="0"
        ;;
    esac

    #设置模组
    at_command="AT+TPVID=2077,${mode_num}"
    sh ${SCRIPT_DIR}/modem_at.sh ${at_port} "${at_command}"
}

#获取位
# $1:频段名称
tw_get_bit()
{
    local band_name="$1"

    local bit
    case "$band_name" in
        "DCS_1800") bit="8" ;;
        "E-GSM_900"|"E_GSM_900") bit="9" ;;
        "P-GSM_900"|"P_GSM_900") bit="10" ;;
        "GSM_450") bit="17" ;;
        "GSM_480") bit="18" ;;
        "GSM_750") bit="19" ;;
        "GSM_850") bit="20" ;;
        "R-GSM_900"|"R_GSM_900") bit="21" ;;
        "PCS_1900") bit="22" ;;
    esac

    echo "${bit}"
}

#获取频段信息
# $1:频段二进制数
# $2:支持的频段
# $3:频段类型（2G，3G，4G，5G）
tw_get_band_info()
{
    local band_bin="$1"
    local support_band="$2"
    local band_type="$3"

    local band_info=""
    local support_band=$(echo "$support_band" | sed 's/,/ /g')
    if [ "$band_type" = "2G" ]; then

        for band in $support_band; do
            #获取bit位
            local bit=$(tw_get_bit ${band})
            #获取值
            local enable="${band_bin: $((-bit)):1}"
            [ -z "$enable" ] && enable="0"
            #设置频段信息
            # band_info=$(echo ${band_info} | jq '. += [{"'$band'":'$enable'}]')
            band_info="${band_info},{\"$band\":$enable}"
        done
    else
        #频段频段起始，前缀位置
        local start_bit
        local band_prefix
        case "$band_type" in
            "3G")
                start_bit="23"
                band_prefix="WCDMA_B"
            ;;
            "4G")
                start_bit="1"
                band_prefix="LTE_BC"
            ;;
            "5G")
                start_bit="1"
                band_prefix="NR5G_N"
            ;;
        esac

        for band in $support_band; do
            #获取值（从start_bit位开始）
            local enable="${band_bin: $((-band-start_bit+1)):1}"
            [ -z "$enable" ] && enable="0"
            #设置频段信息
            # band_info=$(echo ${band_info} | jq '. += [{'$band_prefix$band':'$enable'}]')
            band_info="${band_info},{\"$band_prefix$band\":$enable}"
        done
    fi
    #去掉第一个,
    band_info="["${band_info/,/}"]"
    # band_info="[${band_info%?}]"

    echo "${band_info}"
}

#获取网络偏好
# $1:AT串口
# $2:数据接口
# $3:模组名称
tw_get_network_prefer()
{
    local at_port="$1"
    local data_interface="$2"
    local modem_name="$3"

    at_command='AT+TCFG="nwscanmode"'
    local response=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+TCFG:" | sed 's/\r//g')
    local network_type_num=$(echo "$response" | awk -F',' '{print $2}')

    #获取网络类型
    local network_prefer_2g="0";
    local network_prefer_3g="0";
    local network_prefer_4g="0";
    local network_prefer_5g="0";

    #匹配不同的网络类型
    case "$network_type_num" in
        "0") 
            network_prefer_2g="1"
            network_prefer_3g="1"
            network_prefer_4g="1"
            network_prefer_5g="1"
        ;;
        "1") network_prefer_2g="1" ;;
        "2") network_prefer_3g="1" ;;
        "3") network_prefer_4g="1" ;;
        "4") network_prefer_5g="1" ;;
        "5") network_prefer_5g="1" ;;
    esac

    #获取频段信息
    local band_2g_info="[]"
    local band_3g_info="[]"
    local band_4g_info="[]"
    local band_5g_info="[]"

    #生成网络偏好
    local network_prefer="{
        \"network_prefer\":[
            {\"2G\":{
                \"enable\":$network_prefer_2g,
                \"band\":$band_2g_info
            }},
            {\"3G\":{
                \"enable\":$network_prefer_3g,
                \"band\":$band_3g_info
            }},
            {\"4G\":{
                \"enable\":$network_prefer_4g,
                \"band\":$band_4g_info
            }},
            {\"5G\":{
                \"enable\":$network_prefer_5g,
                \"band\":$band_5g_info
            }}
        ]
    }"
    echo "${network_prefer}"
}

#设置网络偏好
# $1:AT串口
# $2:网络偏好配置
tw_set_network_prefer()
{
    local at_port="$1"
    local network_prefer="$2"

    #获取网络偏好配置
    local network_prefer_config

    #获取选中的数量
    local count=$(echo "$network_prefer" | grep -o "1" | wc -l)
    #获取启用的网络偏好
    local enable_5g=$(echo "$network_prefer" | jq -r '.["5G"].enable')
    local enable_4g=$(echo "$network_prefer" | jq -r '.["4G"].enable')
    local enable_3g=$(echo "$network_prefer" | jq -r '.["3G"].enable')
    local enable_2g=$(echo "$network_prefer" | jq -r '.["2G"].enable')

    case "$count" in
        "1")
            if [ "$enable_2g" = "1" ]; then
                network_prefer_config="1"
            elif [ "$enable_3g" = "1" ]; then
                network_prefer_config="2"
            elif [ "$enable_4g" = "1" ]; then
                network_prefer_config="3"
            elif [ "$enable_5g" = "1" ]; then
                network_prefer_config="4"
            fi
        ;;
        *) network_prefer_config="0" ;;
    esac

    #设置模组
    at_command="AT+TCFG=\"nwscanmode\",${network_prefer_config},1"
    sh ${SCRIPT_DIR}/modem_at.sh $at_port "$at_command"
}

#设置频段
# $1:AT串口
# $2:频段偏好配置
tw_set_band_prefer()
{
    local at_port="$1"
    local network_prefer="$2"

    #获取选中的数量
    local count=$(echo "$network_prefer" | grep -o "1" | wc -l)
    #获取每个偏好的值
    local network_prefer_5g=$(echo "$network_prefer" | jq -r '.["5G"]')
    local network_prefer_4g=$(echo "$network_prefer" | jq -r '.["4G"]')
    local network_prefer_3g=$(echo "$network_prefer" | jq -r '.["3G"]')
    local network_prefer_2g=$(echo "$network_prefer" | jq -r '.["2G"]')

    #获取启用的网络偏好
    local enable_5g=$(echo "$network_prefer_5g" | jq -r '.enable')
    local enable_4g=$(echo "$network_prefer_4g" | jq -r '.enable')
    local enable_3g=$(echo "$network_prefer_3g" | jq -r '.enable')
    local enable_2g=$(echo "$network_prefer_2g" | jq -r '.enable')

    #获取网络偏好配置和频段偏好配置
    local network_prefer_config
    local band_hex_2g_3g=0
    local band_hex_4g_5g=0

    [ "$enable_5g" = "1" ] && {
        network_prefer_config="${network_prefer_config}08"
        local band_tmp=$(echo "$network_prefer_5g" | jq -r '.band[]')
        
        local i=0
        local bands=$(echo "$band_tmp" | jq -r 'to_entries | .[] | .key')
        #遍历band的值
        for band in $bands; do
            local value=$(echo "$network_prefer_5g" | jq -r '.band'"[$i].$band")
            [ "$value" = "1" ] && {
                #获取bit位
                local bit=$(echo "$band" | sed 's/NR5G_N//g')
                #获取值
                local result=$(echo "obase=16; ibase=10; 2^($bit-1)" | bc)
                band_hex_4g_5g=$(echo "obase=16; ibase=16; $band_hex_4g_5g + $result" | bc)
            }
            i=$((i+1))
        done
    }

    [ "$enable_4g" = "1" ] && {
        network_prefer_config="${network_prefer_config}03"
        local band_tmp=$(echo "$network_prefer_4g" | jq -r '.band[]')

        local i=0
        local bands=$(echo "$band_tmp" | jq -r 'to_entries | .[] | .key')
        #遍历band的值
        for band in $bands; do
            local value=$(echo "$network_prefer_4g" | jq -r '.band'"[$i].$band")
            [ "$value" = "1" ] && {
                #获取bit位
                local bit=$(echo "$band" | sed 's/LTE_BC//g')
                #获取值
                local result=$(echo "obase=16; ibase=10; 2^($bit-1)" | bc)
                band_hex_4g_5g=$(echo "obase=16; ibase=16; $band_hex_4g_5g + $result" | bc)
            }
            i=$((i+1))
        done
    }

    [ "$enable_3g" = "1" ] && {
        network_prefer_config="${network_prefer_config}02"
        local band_tmp=$(echo "$network_prefer_3g" | jq -r '.band[]')

        local i=0
        local bands=$(echo "$band_tmp" | jq -r 'to_entries | .[] | .key')
        #遍历band的值
        for band in $bands; do
            local value=$(echo "$network_prefer_3g" | jq -r '.band'"[$i].$band")
            [ "$value" = "1" ] && {
                #获取bit位
                local bit=$(echo "$band" | sed 's/WCDMA_B//g')
                #获取值
                local result=$(echo "obase=16; ibase=10; 2^($bit+22-1)" | bc)
                band_hex_2g_3g=$(echo "obase=16; ibase=16; $band_hex_2g_3g + $result" | bc)
            }
            i=$((i+1))
        done
    }

    [ "$enable_2g" = "1" ] && {
        network_prefer_config="${network_prefer_config}01"
        local band_tmp=$(echo "$network_prefer_2g" | jq -r '.band[]')

        local i=0
        local bands=$(echo "$band_tmp" | jq -r 'to_entries | .[] | .key')
        #遍历band的值
        for band in $bands; do
            # band_format=$(echo "$band" | sed 's/-/_/g')
            local value=$(echo "$network_prefer_2g" | jq -r '.band'"[$i].$band")
            [ "$value" = "1" ] && {
                #获取bit位
                local bit=$(tw_get_bit ${band})
                #获取值
                local result=$(echo "obase=16; ibase=10; 2^($bit-1)" | bc)
                band_hex_2g_3g=$(echo "obase=16; ibase=16; $band_hex_2g_3g + $result" | bc)
            }
            i=$((i+1))
        done
    }

    [ -z "$network_prefer_config" ] && network_prefer_config="99"

    #设置模组
    at_command='AT^SYSCFGEX="'${network_prefer_config}'",'"${band_hex_2g_3g},1,2,${band_hex_4g_5g},,"
    sh ${SCRIPT_DIR}/modem_at.sh "${at_port}" "${at_command}"
}

#获取电压
# $1:AT串口
tw_get_voltage()
{
    local at_port="$1"
    
    # #Voltage（电压）
    # at_command="AT+ADCREAD=0"
	# local voltage=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | grep "+ADCREAD:" | awk -F' ' '{print $2}' | sed 's/\r//g')
    # voltage=$(awk "BEGIN{ printf \"%.2f\", $voltage / 1000000 }" | sed 's/\.*0*$//')
    # echo "${voltage}"
}

#获取温度
# $1:AT串口
tw_get_temperature()
{
    local at_port="$1"
    
    #Temperature（温度）
    at_command="AT+TEMP"
	response=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | grep "+TEMP:" | awk -F',' '{print $2}' | sed 's/\r//g')

    local temperature
	if [ -n "$response" ]; then
        response=$(awk "BEGIN{ printf \"%.2f\", $response / 10 }" | sed 's/\.*0*$//')
		temperature="${response}$(printf "\xc2\xb0")C"
    else
        temperature="NaN $(printf "\xc2\xb0")C"
	fi

    echo "${temperature}"
}

#获取连接状态
# $1:AT串口
# $2:连接定义
tw_get_connect_status()
{
    local at_port="$1"
    local define_connect="$2"

    #默认值为1
    [ -z "$define_connect" ] && {
        define_connect="1"
    }

    at_command="AT+CGPADDR=${define_connect}"
    local ipv4=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+CGPADDR: " | awk -F',' '{print $2}')
    local not_ip="0.0.0.0"

    #设置连接状态
    local connect_status
    if [ -z "$ipv4" ] || [[ "$ipv4" = *"$not_ip"* ]]; then
        connect_status="disconnect"
    else
        connect_status="connect"
    fi

    echo "${connect_status}"
}

#基本信息
tw_base_info()
{
    debug "tw base info"

    #Name（名称）
    at_command="AT+CGMM"
    name=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | sed -n '2p' | sed 's/\r//g')
    #Manufacturer（制造商）
    at_command="AT+CGMI"
    manufacturer=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | sed -n '2p' | sed 's/\r//g')
    #Revision（固件版本）
    at_command="AT+CGMR"
    revision=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | sed -n '2p' | sed 's/\r//g')

    #Mode（拨号模式）
    mode=$(tw_get_mode ${at_port} ${platform} | tr 'a-z' 'A-Z')

    #Temperature（温度）
    temperature=$(tw_get_temperature ${at_port})
}

#获取SIM卡状态
# $1:SIM卡状态标志
tw_get_sim_status()
{
    local sim_status
    case $1 in
        "") sim_status="miss" ;;
        *"ERROR"*) sim_status="miss" ;;
        *"READY"*) sim_status="ready" ;;
        *"SIM PIN"*) sim_status="MT is waiting SIM PIN to be given" ;;
        *"SIM PUK"*) sim_status="MT is waiting SIM PUK to be given" ;;
        *"PH-FSIM PIN"*) sim_status="MT is waiting phone-to-SIM card password to be given" ;;
        *"PH-FSIM PIN"*) sim_status="MT is waiting phone-to-very first SIM card password to be given" ;;
        *"PH-FSIM PUK"*) sim_status="MT is waiting phone-to-very first SIM card unblocking password to be given" ;;
        *"SIM PIN2"*) sim_status="MT is waiting SIM PIN2 to be given" ;;
        *"SIM PUK2"*) sim_status="MT is waiting SIM PUK2 to be given" ;;
        *"PH-NET PIN"*) sim_status="MT is waiting network personalization password to be given" ;;
        *"PH-NET PUK"*) sim_status="MT is waiting network personalization unblocking password to be given" ;;
        *"PH-NETSUB PIN"*) sim_status="MT is waiting network subset personalization password to be given" ;;
        *"PH-NETSUB PUK"*) sim_status="MT is waiting network subset personalization unblocking password to be given" ;;
        *"PH-SP PIN"*) sim_status="MT is waiting service provider personalization password to be given" ;;
        *"PH-SP PUK"*) sim_status="MT is waiting service provider personalization unblocking password to be given" ;;
        *"PH-CORP PIN"*) sim_status="MT is waiting corporate personalization password to be given" ;;
        *"PH-CORP PUK"*) sim_status="MT is waiting corporate personalization unblocking password to be given" ;;
        *) sim_status="unknown" ;;
    esac
    echo "${sim_status}"
}

#SIM卡信息
tw_sim_info()
{
    debug "tw sim info"
    
    #SIM Slot（SIM卡卡槽）
    # at_command="AT^SIMSLOT?"
	# response=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "\^SIMSLOT:" | awk -F': ' '{print $2}' | awk -F',' '{print $2}')

    # if [ "$response" != "0" ]; then
    #     sim_slot="1"
    # else
    #     sim_slot="2"
    # fi
    sim_slot="1"

    #IMEI（国际移动设备识别码）
    at_command="AT+CGSN"
	imei=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | sed -n '2p' | sed 's/\r//g')

    #SIM Status（SIM状态）
    at_command="AT+CPIN?"
	sim_status_flag=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+CPIN: ")
    sim_status=$(tw_get_sim_status "$sim_status_flag")

    if [ "$sim_status" != "ready" ]; then
        return
    fi

    #ISP（互联网服务提供商）
    at_command="AT+COPS?"
    isp=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+COPS" | awk -F'"' '{print $2}')
    # if [ "$isp" = "CHN-CMCC" ] || [ "$isp" = "CMCC" ] || [ "$isp" = "46000" ]; then
    #     isp="中国移动"
    # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "UNICOM" ] || [ "$isp" = "46001" ]; then
    #     isp="中国联通"
    # elif [ "$isp" = "CHN-CT" ] || [ "$isp" = "CT" ] || [ "$isp" = "46011" ]; then
    #     isp="中国电信"
    # fi

    #SIM Number（SIM卡号码，手机号）
    at_command="AT+CNUM"
	sim_number=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+CNUM: " | awk -F'"' '{print $2}')
    [ -z "$sim_number" ] && {
        sim_number=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+CNUM: " | awk -F'"' '{print $4}')
    }
	
    #IMSI（国际移动用户识别码）
    at_command="AT+CIMI"
	imsi=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | sed -n '2p' | sed 's/\r//g')

    #ICCID（集成电路卡识别码）
    at_command="AT+ICCID"
	iccid=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep -o "+ICCID:[ ]*[-0-9]\+" | grep -o "[-0-9]\{1,4\}")
}

#获取网络类型
# $1:网络类型数字
tw_get_rat()
{
    local rat
    case $1 in
		"0"|"1"|"3"|"8") rat="GSM" ;;
		"2"|"4"|"5"|"6"|"9"|"10") rat="WCDMA" ;;
        "7") rat="LTE" ;;
        "11"|"12") rat="NR" ;;
	esac
    echo "${rat}"
}

#网络信息
tw_network_info()
{
    debug "tw network info"

    #Connect Status（连接状态）
    connect_status=$(tw_get_connect_status ${at_port} ${define_connect})
    if [ "$connect_status" != "connect" ]; then
        return
    fi

    #Network Type（网络类型）
    at_command="AT+TNWINFO"
    network_type=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+TNWINFO:" | awk -F'"' '{print $2}')

    [ -z "$network_type" ] && {
        at_command='AT+COPS?'
        local rat_num=$(sh ${SCRIPT_DIR}/modem_at.sh ${at_port} ${at_command} | grep "+COPS:" | awk -F',' '{print $4}' | sed 's/\r//g')
        network_type=$(tw_get_rat ${rat_num})
    }

    #设置网络类型为5G时，信号强度指示用RSRP代替
    # at_command="AT+GTCSQNREN=1"
    # sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command

    #CSQ（信号强度）
    at_command="AT+CSQ"
    response=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | grep "+CSQ:" | sed 's/+CSQ: //g' | sed 's/\r//g')

    #RSSI（4G信号强度指示）
    # rssi_num=$(echo $response | awk -F',' '{print $1}')
    # rssi=$(tw_get_rssi $rssi_num)
    #BER（4G信道误码率）
    # ber=$(echo $response | awk -F',' '{print $2}')

    # #PER（信号强度）
    # if [ -n "$csq" ]; then
    #     per=$(($csq * 100/31))"%"
    # fi

    # #AMBR（最大比特率）
    # at_command="AT^DSAMBR=${define_connect}"
    # response=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | grep "\^DSAMBR:" | sed 's/\^DSAMBR: //g' | sed 's/\r//g')
    # ambr_ul_tmp=$(echo "$response" | awk -F',' '{print $2}')
    # ambr_dl_tmp=$(echo "$response" | awk -F',' '{print $3}')

    # #AMBR UL（上行签约速率，单位，Mbps）
    # ambr_ul=$(awk "BEGIN{ printf \"%.2f\", $ambr_ul_tmp / 1000 }" | sed 's/\.*0*$//')
    # #AMBR DL（下行签约速率，单位，Mbps）
    # ambr_dl=$(awk "BEGIN{ printf \"%.2f\", $ambr_dl_tmp / 1000 }" | sed 's/\.*0*$//')

    # #速率统计
    # at_command='AT^DSFLOWQRY'
    # response=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command | grep "\^DSFLOWRPT:" | sed 's/\^DSFLOWRPT: //g' | sed 's/\r//g')

    # #当前上传速率（单位，Byte/s）
    # tx_rate=$(echo $response | awk -F',' '{print $1}')

    # #当前下载速率（单位，Byte/s）
    # rx_rate=$(echo $response | awk -F',' '{print $2}')
}

#获取带宽
# $1:网络类型
# $2:带宽数字
tw_get_bandwidth()
{
    local network_type="$1"
    local bandwidth_num="$2"

    local bandwidth
    case $network_type in
        "NR")
            case $bandwidth_num in
                *) bandwidth="$bandwidth_num" ;;
            esac
        ;;
	esac
    echo "$bandwidth"
}

#小区信息
tw_cell_info()
{
    debug "tw cell info"

    at_command="AT+TCELLINFO"
    response=$(sh ${SCRIPT_DIR}/modem_at.sh $at_port $at_command)
    
    local rat=$(echo "$response" | grep "MODE:" | awk -F' ' '{print $2}')

    case $rat in
        "NR5G")
            network_mode="NR5G-SA Mode"
            nr_mcc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 1, 3)}')
            nr_mnc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 4, 5)}')
            nr_band=$(echo "$response" | grep " BAND " | awk -F' ' '{print $3}' | sed 's/[^0-9]//g')
            nr_arfcn=$(echo "$response" | grep "CHANNEL:" | sed 's/[^0-9]//g')
            nr_tac=$(echo "$response" | grep "TAC:" | awk -F'"' '{print $2}')
            nr_dl_bandwidth_num=$(echo "$response" | grep "BAND WIDTH:" | sed 's/[^0-9]//g')
            nr_dl_bandwidth=$(tw_get_bandwidth "NR" ${nr_dl_bandwidth_num})
            nr_cell_id=$(echo "$response" | grep "CELL ID:" | sed 's/[^0-9]//g')
            nr_physical_cell_id=$(echo "$response" | grep "PCI:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            nr_rsrp=$(echo "$response" | grep "RSRP:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            nr_rsrq=$(echo "$response" | grep "RSRQ:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            nr_sinr=$(echo "$response" | grep "SINR:" | awk -F' ' '{print $2}' | sed 's/\r//g')
        ;;
        "LTE"|"eMTC"|"NB-IoT")
            network_mode="LTE Mode"
            lte_mcc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 1, 3)}')
            lte_mnc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 4, 5)}')
            lte_band=$(echo "$response" | grep "BAND:" | awk -F' ' '{print $4}' | sed 's/[^0-9]//g')
            lte_earfcn=$(echo "$response" | grep "EARFCN DL/UL:" | awk -F' ' '{print $3}' | sed 's/\r//g')
            lte_dl_bandwidth=$(echo "$response" | grep "BAND WIDTH:" | sed 's/[^0-9]//g')
            lte_cell_id=$(echo "$response" | grep "CELL ID:" | sed 's/[^0-9]//g')
            lte_tac=$(echo "$response" | grep "TAC:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            lte_rssi=$(echo "$response" | grep "RSSI:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            lte_rsrp=$(echo "$response" | grep "RSRP:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            lte_rsrq=$(echo "$response" | grep "RSRQ:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            lte_sinr=$(echo "$response" | grep "SINR:" | awk -F' ' '{print $2}' | sed 's/\r//g')
        ;;
        "WCDMA"|"TD-SCDMA"|"UMTS"|"HSPA+")
            network_mode="WCDMA Mode"
            wcdma_mcc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 1, 3)}')
            wcdma_mnc=$(echo "$response" | grep "PLMN:" | awk -F'"' '{print substr($2, 4, 5)}')
            wcdma_band=$(echo "$response" | grep "BAND:" | awk -F' ' '{print $3}' | sed 's/[^0-9]//g')
            wcdma_uarfcn=$(echo "$response" | grep "CHANNEL:" | sed 's/[^0-9]//g')
            wcdma_cell_id=$(echo "$response" | grep "CELL ID:" | sed 's/[^0-9]//g')
            wcdma_psc=$(echo "$response" | grep "PSC:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            wcdma_lac=$(echo "$response" | grep "LAC ID:" | awk -F' ' '{print $3}' | sed 's/\r//g')
            wcdma_rssi=$(echo "$response" | grep "RSSI:" | awk -F' ' '{print $2}' | sed 's/\r//g')
            wcdma_ecio=$(echo "$response" | grep "EC/IO:" | awk -F' ' '{print $2}' | sed 's/\r//g')
        ;;
    esac
}

#获取鼎桥模组信息
# $1:AT串口
# $2:平台
# $3:连接定义
get_tw_info()
{
    debug "get tw info"
    #设置AT串口
    at_port="$1"
    platform="$2"
    define_connect="$3"

    #基本信息
    tw_base_info

	#SIM卡信息
    tw_sim_info
    if [ "$sim_status" != "ready" ]; then
        return
    fi

    #网络信息
    tw_network_info
    if [ "$connect_status" != "connect" ]; then
        return
    fi

    #小区信息
    tw_cell_info
}