#!/usr/bin/env fish

sudo -v

set HP /sys/devices/platform/hp-wmi/hwmon/hwmon8

function restore_ec --on-signal INT
    echo 2 | sudo -n tee "$HP/pwm1_enable" >/dev/null
    echo
    echo "HP EC automatic fan control restored."
    exit 130
end

while true

    set cpu (sensors 2>/dev/null | awk '/Package id 0:/ {gsub(/[+°C]/,"",$4); print $4}')
    set gpu (nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)

    if test -z "$cpu"
        set cpu 0
    end

    if test -z "$gpu"
        set gpu 0
    end

    set temp (math "max($cpu,$gpu)")

    if test $temp -ge 86
        echo 0 | sudo -n tee "$HP/pwm1_enable" >/dev/null
        set pwm "HP MAX"
    else
        echo 1 | sudo -n tee "$HP/pwm1_enable" >/dev/null

        if test $temp -lt 60
            set value 128
        else if test $temp -lt 70
            set value 160
        else if test $temp -lt 80
            set value 192
        else
            set value 255
        end

        echo $value | sudo -n tee "$HP/pwm1" >/dev/null
        set pwm $value
    end

    set fan1 (cat "$HP/fan1_input" 2>/dev/null)
    set fan2 (cat "$HP/fan2_input" 2>/dev/null)

    printf "\033[H\033[J"
    printf "HP FAN CURVE\n"
    printf "==============================\n"
    printf "CPU        : %s°C\n" $cpu
    printf "GPU        : %s°C\n" $gpu
    printf "HOTTEST    : %s°C\n" $temp
    printf "PWM        : %s\n" $pwm
    printf "FAN1       : %s RPM\n" $fan1
    printf "FAN2       : %s RPM\n" $fan2
    printf "\n"
    printf "<60°C  = PWM 128\n"
    printf "60-69°C = PWM 160\n"
    printf "70-79°C = PWM 192\n"
    printf "80-85°C = PWM 255\n"
    printf "≥86°C  = HP MAX FAN\n"
    printf "CTRL+C = RESTORE EC AUTO\n"

    sleep 2
end
