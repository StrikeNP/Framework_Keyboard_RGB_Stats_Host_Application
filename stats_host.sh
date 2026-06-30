#!/usr/bin/env bash

REPORT_LENGTH=32
GPU_UPDATE_INTERVAL=10
GPU_LAST_UPDATE=0
GPU_HWMON=""
gpu_power=0
gpu_cap=1
gpu_temp=0
d3cold=0
muted=0
cpu_percent=0
mem_percent=0
battery_percent=0
battery_watts=0
discharging=255
cpu_temp=0
wifi=0


#
# ------------------------- # Utilities
# -------------------------
#

safe_div_mw() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo 0; return; }
    echo $((v / 1000000))
}

clamp_u8() {
    local v="$1"
    (( v < 0 )) && { echo 0; return; }
    (( v > 255 )) && { echo 255; return; }
    echo "$v"
}

#
# -------------------------
# HID detection
# -------------------------
#

find_hid() {
    for d in /sys/class/hidraw/hidraw*; do
        [[ -f "$d/device/report_descriptor" ]] || continue

        desc=$(hexdump -v -e '1/1 "%02X "' "$d/device/report_descriptor" 2>/dev/null)

        if echo "$desc" | grep -qi "06 60 FF" &&
           echo "$desc" | grep -qi "09 61"; then
            basename "$d"
            return 0
        fi
    done
}

init_hid() {
    hid_name=$(find_hid)
    HID="${hid_name:+/dev/$hid_name}"

    echo "Found keyboard HID: $HID"

    if [[ ! -e "$HID" ]]; then
        echo "HID device not found. Packets will not be sent."
        HID=""
    fi
}

#
# -------------------------
# WiFi
# -------------------------
#

read_wifi() {
    wifi=0

    for iface in /sys/class/net/*; do
        [[ -d "$iface/wireless" ]] || continue

        operstate="$iface/operstate"
        [[ -f "$operstate" ]] || continue

        if [[ $(<"$operstate") == "up" ]]; then
            wifi=1
            return
        fi
    done
}

#
# -------------------------
# Audio
# -------------------------
#

read_mute() {
    muted=0

    if pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -q "yes"; then
        muted=1
    else
    	muted=0
    fi
}


#
# -------------------------
# Battery
# -------------------------
#

find_battery() {
    for bat in /sys/class/power_supply/*; do
        [[ -f "$bat/type" ]] || continue

        if [[ $(<"$bat/type") == "Battery" ]]; then
            echo "$bat"
            return 0
        fi
    done
}

read_battery() {
    BAT=$(find_battery)

    battery_percent=0
    battery_watts=0
    discharging=255

    if [[ -n "$BAT" ]]; then
        battery_percent=$(<"$BAT/capacity")
        battery_state=$(<"$BAT/status")

        if [[ -f "$BAT/power_now" ]]; then
            battery_watts=$(safe_div_mw "$(cat "$BAT/power_now")")

        elif [[ -f "$BAT/current_now" && -f "$BAT/voltage_now" ]]; then
            current_now=$(<"$BAT/current_now")
            voltage_now=$(<"$BAT/voltage_now")

            battery_watts=$(awk -v c="$current_now" -v v="$voltage_now" '
                BEGIN { printf "%d", (c*v)/1000000000000 }
            ')
        elif [[ -f "$BAT/power" ]]; then
            battery_watts=$(( $(<"$BAT/power") / 1000000 ))
        fi

        case "$battery_state" in
            Charging)    discharging=0 ;;
            Discharging) discharging=1 ;;
            *)           discharging=255 ;;
        esac
    fi

    battery_percent=$(clamp_u8 "$battery_percent")
    battery_watts=$(clamp_u8 "$battery_watts")
}

#
# -------------------------
# CPU
# -------------------------
#

read_cpu() {
    read cpu user nice system idle iowait irq softirq steal guest guestnice < /proc/stat
    total=$((user+nice+system+idle+iowait+irq+softirq+steal+guest+guestnice))

    sleep 1

    read cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guestnice2 < /proc/stat
    total2=$((user2+nice2+system2+idle2+iowait2+irq2+softirq2+steal2+guest2+guestnice2))

    diff_total=$((total2-total))
    diff_idle=$((idle2-idle))

    cpu_percent=0
    if (( diff_total > 0 )); then
        cpu_percent=$((100*(diff_total-diff_idle)/diff_total))
    fi

    cpu_percent=$(clamp_u8 "$cpu_percent")
}

#
# -------------------------
# Memory
# -------------------------
#

read_memory() {
    mem_percent=$(awk '
        /MemTotal/ {t=$2}
        /MemAvailable/ {a=$2}
        END {
            if (t > 0)
                printf "%d",100-(100*a/t);
            else
                print 0;
        }
    ' /proc/meminfo)

    mem_percent=$(clamp_u8 "$mem_percent")
}

#
# -------------------------
# CPU temperature
# -------------------------
#
read_cpu_temp() {
    cpu_temp=0

    for hw in /sys/class/hwmon/hwmon*; do
        [[ -r "$hw/name" ]] || continue
        case "$(cat "$hw/name")" in
            k10temp|coretemp)
                for t in "$hw"/temp*_input; do
                    [[ -r "$t" ]] || continue
                    temp=$(<"$t")
                    (( temp > cpu_temp )) && cpu_temp=$temp
                done
                ;;
        esac
    done

    cpu_temp=$((cpu_temp / 1000))
}




#
# -------------------------
# GPU (10s refresh, D3cold-safe)
# -------------------------
#


select_gpu() {
    GPU_HWMON=""
    gpu_cap=1

    d3cold_list=()
    hot_list=()
    d3cold=0
    for drm_card in /sys/class/drm/card*/device; do
    	class_file="$drm_card/class"
        state_file="$drm_card/power_state"

        [[ -f "$class_file" ]] || continue
        class=$(<"$class_file")

        [[ "$class" == 0x03* ]] || continue

    	drm_state=$(<"$drm_card/power_state")
        if [[ "$drm_state" == *D3cold* ]]; then
		d3cold_list+=($drm_card)
		d3cold=1
	else
		hot_list+=("$drm_card/hwmon/hwmon*")
	fi
    done
    

    for hw in $hot_list; do
        #[[ -f "$hw/power1_cap" ]] || continue
        dev_path=$(dirname "$(dirname "$hw")")
        
	if [[ -f "$hw/power1_cap" ]]; then
    		cap=$(<"$hw/power1_cap")
	else
    		cap=1
	fi

	cap=$(safe_div_mw "$cap")

        if (( cap >= gpu_cap )); then
            gpu_cap=$cap
            GPU_HWMON=$hw
        fi
    done
}

read_gpu() {
    gpu_power=0
    gpu_temp=0

    if [[ -n "$GPU_HWMON" ]]; then
        [[ -f "$GPU_HWMON/power1_average" ]] &&
            gpu_power=$(safe_div_mw "$(cat "$GPU_HWMON/power1_average")")

        #gpu_cap=$(safe_div_mw "$gpu_cap")

        for t in "$GPU_HWMON"/temp*_input; do
            [[ -f "$t" ]] || continue
            gpu_temp_t=$(($(<"$t")/1000))
	    if (( $gpu_temp_t > $gpu_temp )); then gpu_temp=$gpu_temp_t; fi
            #break
        done
    fi

    gpu_power=$(clamp_u8 "$gpu_power")
    gpu_cap=$(clamp_u8 "$gpu_cap")
    gpu_temp=$(clamp_u8 "$gpu_temp")
}

update_gpu_if_needed() {
    now=$(date +%s)

    if (( now - GPU_LAST_UPDATE >= GPU_UPDATE_INTERVAL )); then
    	select_gpu
    	echo "Querying GPU! $GPU_HWMON"
        GPU_LAST_UPDATE=$now

        read_gpu

        if [[ -n "$GPU_HWMON" ]]; then
            echo "Using GPU:"
            echo "  hwmon : $GPU_HWMON"
            echo "  device: $(dirname "$(dirname "$GPU_HWMON")")"
        else
            echo "No active (non-D3cold) GPU found."
        fi
    fi
}

#
# -------------------------
# Main
# -------------------------
#

init_hid

while true; do
    
    read_cpu
    read_memory
    read_battery
    read_wifi
    read_mute
    read_cpu_temp
    update_gpu_if_needed

	printf "CPU:%02X MEM:%02X BATT_W:%02X DISCHARGING:%02X CPU_TEMP:%02X D3COLD:%02X VOLUME:%02X BATT:%%:%02X MUTED:%02X WIFI:%02X GPU_POWER:%02X GPU_CAP:%02X GPU_TEMP:%02X\n" \
    "$cpu_percent" \
    "$mem_percent" \
    "$battery_watts" \
    "$discharging" \
    "$cpu_temp" \
    "$d3cold" \
    255 \
    "$battery_percent" \
    "$muted" \
    "$wifi" \
    "$gpu_power" \
    "$gpu_cap" \
    "$gpu_temp"


    packet=(
        07 3F
        $(printf "%02X" "$cpu_percent")
        $(printf "%02X" "$mem_percent")
        $(printf "%02X" "$battery_watts")
        $(printf "%02X" "$discharging")
        $(printf "%02X" "$cpu_temp")
        $(printf "%02X" "$d3cold")
	FF # Volume level, 0-100. Not supported by keyboard yet, so not implemented.
        $(printf "%02X" "$battery_percent")
        $(printf "%02X" "$muted")
        $(printf "%02X" "$wifi")
        $(printf "%02X" "$gpu_power")
        $(printf "%02X" "$gpu_cap")
        $(printf "%02X" "$gpu_temp")
    )

    while ((${#packet[@]} < REPORT_LENGTH)); do
        packet+=(07)
    done

    hex=""
    for b in "${packet[@]}"; do
        hex+="\\x$b"
    done
    echo "$hex"

    if [[ -n "$HID" ]]; then
        printf '%b' "$hex" >"$HID" || echo "write failed: $?"
    fi

done
