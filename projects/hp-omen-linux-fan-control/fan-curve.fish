#!/usr/bin/env fish

# ============================================================
# HP FAN CURVE
#
# CPU/GPU >= 86°C:
#   -> HP MAX FAN
#   -> Hold MAX for 15 minutes
#
# Normal curve:
#   <60°C    -> PWM 128
#   60-69°C  -> PWM 160
#   70-79°C  -> PWM 192
#   80-85°C  -> PWM 255
#
# Higher PWM level:
#   -> Hold for minimum 5 minutes
#
# Performance profile:
#   -> Re-applied every loop
#
# CTRL+C:
#   -> Restore HP EC automatic fan control
# ============================================================

sudo -v

# ============================================================
# FIND HP HWMON DEVICE
# ============================================================

set HP ""

for hw in /sys/class/hwmon/hwmon*

    if not test -r "$hw/name"
        continue
    end

    set name (cat "$hw/name" 2>/dev/null | string trim)

    if test "$name" = "hp"; or test "$name" = "hp-wmi"

        if test -e "$hw/pwm1"; and test -e "$hw/pwm1_enable"
            set HP "$hw"
            break
        end

    end
end

# ============================================================
# IF NOT FOUND
# ============================================================

if test -z "$HP"

    clear

    echo "========================================"
    echo "       HP FAN CONTROL ERROR"
    echo "========================================"
    echo
    echo "HP hwmon device with PWM control"
    echo "was not found."
    echo
    echo "Available hwmon devices:"
    echo

    for hw in /sys/class/hwmon/hwmon*

        if test -r "$hw/name"

            set name (cat "$hw/name" 2>/dev/null | string trim)

            printf "  %-35s -> %s\n" "$hw" "$name"

        end
    end

    echo
    echo "Press ENTER to exit..."
    read
    exit 1
end

# ============================================================
# RESTORE EC AUTOMATIC FAN CONTROL
# ============================================================

function restore_ec --on-signal INT

    if test -e "$HP/pwm1_enable"
        echo 2 | sudo -n tee "$HP/pwm1_enable" >/dev/null
    end

    echo
    echo "HP EC automatic fan control restored."
    exit 130
end

# ============================================================
# READ FAN RPM
# ============================================================

function read_rpm

    set file $argv[1]

    if not test -r "$file"
        return 1
    end

    set rpm (cat "$file" 2>/dev/null | string trim)

    if string match -rq '^[0-9]+$' -- "$rpm"
        echo "$rpm"
        return 0
    end

    return 1
end

# ============================================================
# INITIAL VALUES
# ============================================================

# Current manual PWM level
set current_value 128

# Time when PWM was last increased
set increase_time (date +%s)

# MAX FAN hold expiration time
set max_fan_until 0

# ============================================================
# MAIN LOOP
# ============================================================

while true

    # ========================================================
    # KEEP HP PERFORMANCE PROFILE ACTIVE
    # ========================================================

    echo performance | sudo -n tee /sys/firmware/acpi/platform_profile >/dev/null

    # ========================================================
    # READ FAN RPM
    # ========================================================

    set fan1 ""
    set fan2 ""

    set fan1 (read_rpm "$HP/fan1_input")
    set fan2 (read_rpm "$HP/fan2_input")

    set fan1_ok 0
    set fan2_ok 0

    if test (count $fan1) -gt 0
        set fan1_ok 1
    end

    if test (count $fan2) -gt 0
        set fan2_ok 1
    end

    # ========================================================
    # NO RPM = DO NOT CHANGE PWM
    # ========================================================

    if test $fan1_ok -eq 0; and test $fan2_ok -eq 0

        printf "\033[H\033[J"

        echo "========================================"
        echo "             HP FAN CURVE"
        echo "========================================"
        echo
        printf "HWMON      : %s\n" "$HP"
        echo
        echo "WARNING: FAN RPM CANNOT BE READ"
        echo
        echo "Fan speed will NOT be changed."
        echo
        echo "FAN1       : N/A"
        echo "FAN2       : N/A"
        echo
        echo "Checking again..."
        echo
        echo "CTRL+C = EXIT"

        sleep 2
        continue
    end

    # ========================================================
    # CPU TEMPERATURE
    # ========================================================

    set cpu (
        sensors 2>/dev/null |
        awk '/Package id 0:/ {
            gsub(/[+°C]/,"",$4);
            print $4
        }' |
        head -n 1
    )

    if not string match -rq '^[0-9]+([.][0-9]+)?$' -- "$cpu"
        set cpu 0
    end

    # ========================================================
    # NVIDIA GPU TEMPERATURE
    # ========================================================

    set gpu (
        nvidia-smi \
        --query-gpu=temperature.gpu \
        --format=csv,noheader \
        2>/dev/null |
        head -n 1 |
        string trim
    )

    if not string match -rq '^[0-9]+([.][0-9]+)?$' -- "$gpu"
        set gpu 0
    end

    # ========================================================
    # HOTTEST TEMPERATURE
    # ========================================================

    set temp (math "max($cpu,$gpu)")

    # ========================================================
    # CURRENT TIME
    # ========================================================

    set now (date +%s)

    # ========================================================
    # 86°C EMERGENCY TRIGGER
    #
    # Any CPU/GPU >= 86°C:
    #   Start/reset 15-minute MAX FAN timer
    # ========================================================

    if test $temp -ge 86
        set max_fan_until (math "$now + 900")
    end

    # ========================================================
    # MAX FAN MODE
    # ========================================================

    if test $now -lt $max_fan_until

        # HP maximum fan mode
        echo 0 | sudo -n tee "$HP/pwm1_enable" >/dev/null

        set pwm "HP MAX"

        set remaining (math "$max_fan_until - $now")

    else

        # ====================================================
        # NORMAL MANUAL PWM MODE
        # ====================================================

        echo 1 | sudo -n tee "$HP/pwm1_enable" >/dev/null

        # ====================================================
        # NORMAL FAN CURVE
        # ====================================================

        if test $temp -lt 60
            set target 128

        else if test $temp -lt 70
            set target 160

        else if test $temp -lt 80
            set target 192

        else
            set target 255
        end

        # ====================================================
        # FAN SPEED INCREASE
        #
        # Higher speed immediately allowed.
        # Start 5-minute hold timer.
        # ====================================================

        if test $target -gt $current_value

            set current_value $target
            set increase_time $now

        end

        # ====================================================
        # FAN SPEED DECREASE
        #
        # Only allow after 5 minutes.
        # ====================================================

        set held_for (math "$now - $increase_time")

        if test $target -lt $current_value

            if test $held_for -ge 300
                set current_value $target
            end

        end

        # ====================================================
        # APPLY PWM
        # ====================================================

        echo $current_value | sudo -n tee "$HP/pwm1" >/dev/null

        set pwm $current_value
        set remaining 0

    end

    # ========================================================
    # DISPLAY
    # ========================================================

    printf "\033[H\033[J"

    echo "========================================"
    echo "             HP FAN CURVE"
    echo "========================================"

    printf "HWMON      : %s\n" "$HP"
    echo
    printf "CPU        : %s°C\n" "$cpu"
    printf "GPU        : %s°C\n" "$gpu"
    printf "HOTTEST    : %s°C\n" "$temp"
    echo
    printf "PWM        : %s\n" "$pwm"

    if test $fan1_ok -eq 1
        printf "FAN1       : %s RPM\n" "$fan1"
    else
        printf "FAN1       : N/A\n"
    end

    if test $fan2_ok -eq 1
        printf "FAN2       : %s RPM\n" "$fan2"
    else
        printf "FAN2       : N/A\n"
    end

    echo

    if test $now -lt $max_fan_until
        printf "MAX HOLD   : %s sec remaining\n" "$remaining"
    else
        echo "MAX HOLD   : INACTIVE"
    end

    echo
    echo "<60°C    = PWM 128"
    echo "60-69°C  = PWM 160"
    echo "70-79°C  = PWM 192"
    echo "80-85°C  = PWM 255"
    echo "≥86°C    = MAX FAN / 15 MIN"
    echo
    echo "Higher PWM held for 5 minutes"
    echo "HP Performance profile: ACTIVE"
    echo
    echo "CTRL+C = RESTORE EC AUTO"

    sleep 2

end
