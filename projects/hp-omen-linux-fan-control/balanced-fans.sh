#!/usr/bin/env bash

# ========================================
# HP OMEN BALANCED FAN CURVE
# ========================================

# Ask for sudo password at startup
sudo -v || exit 1

# Keep sudo alive in the background
while true; do
    sudo -n -v
    sleep 30
    kill -0 "$$" 2>/dev/null || exit
done 2>/dev/null &


# ========================================
# SETTINGS
# ========================================

MAX_THRESHOLD=86
MAX_PWM=255
MAX_HOLD_TIME=300          # 5 minutes

STEP_UP_DELAY=8            # seconds before normal speed increase
STEP_DOWN_DELAY=60         # seconds before lowering fan speed

CHECK_INTERVAL=1


# ========================================
# FIND HP FAN CONTROLLER
# ========================================

HP=""

for hw in /sys/class/hwmon/hwmon*; do

    NAME=$(cat "$hw/name" 2>/dev/null)

    if { [ "$NAME" = "hp" ] || [ "$NAME" = "hp-wmi" ]; } \
        && [ -e "$hw/pwm1" ] \
        && [ -e "$hw/pwm1_enable" ]; then

        HP="$hw"
        break
    fi

done


if [ -z "$HP" ]; then
    echo "❌ HP fan controller not found."
    exit 1
fi


# ========================================
# FIND CPU PACKAGE TEMPERATURE
# ========================================

CPU_TEMP=""

for hw in /sys/class/hwmon/hwmon*; do

    if [ -f "$hw/name" ]; then

        NAME=$(cat "$hw/name" 2>/dev/null)

        if [ "$NAME" = "coretemp" ]; then

            for label in "$hw"/temp*_label; do

                if [ -f "$label" ]; then

                    LABEL=$(cat "$label" 2>/dev/null)

                    if [ "$LABEL" = "Package id 0" ]; then

                        CPU_TEMP="${label/_label/_input}"
                        break

                    fi

                fi

            done

        fi

    fi

    [ -n "$CPU_TEMP" ] && break

done


if [ -z "$CPU_TEMP" ]; then
    echo "❌ CPU Package temperature sensor not found."
    exit 1
fi


# ========================================
# CHECK NVIDIA
# ========================================

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "❌ nvidia-smi not found."
    exit 1
fi


# ========================================
# RESTORE HP AUTOMATIC CONTROL
# ========================================

restore_hp_control() {

    echo 2 | sudo tee "$HP/pwm1_enable" >/dev/null

    echo
    echo "🟢 HP automatic fan control restored."

}


# ========================================
# APPLY PWM
# ========================================

apply_pwm() {

    local PWM="$1"

    # Enable manual PWM mode
    echo 1 | sudo tee "$HP/pwm1_enable" >/dev/null

    # Apply requested PWM
    echo "$PWM" | sudo tee "$HP/pwm1" >/dev/null

}


# ========================================
# READ TEMPERATURES
# ========================================

get_cpu_temp() {

    local RAW

    RAW=$(cat "$CPU_TEMP" 2>/dev/null)

    if [ -n "$RAW" ]; then
        echo $((RAW / 1000))
    fi

}


get_gpu_temp() {

    nvidia-smi \
        --query-gpu=temperature.gpu \
        --format=csv,noheader,nounits \
        2>/dev/null | head -n 1 | tr -d ' '

}


# ========================================
# CLEAN EXIT
# ========================================

cleanup() {

    echo
    echo "CTRL+C detected."
    restore_hp_control
    exit 0

}

trap cleanup INT TERM


# ========================================
# FAN CURVE
# ========================================

get_target_pwm() {

    local TEMP="$1"

    if [ "$TEMP" -le 45 ]; then

        echo 0

    elif [ "$TEMP" -le 69 ]; then

        echo 100

    elif [ "$TEMP" -le 85 ]; then

        echo 190

    else

        echo 255

    fi

}


# ========================================
# STARTUP
# ========================================

restore_hp_control

clear

echo "========================================"
echo "       HP OMEN FAN CURVE CONTROL"
echo "========================================"
echo
echo "HP controller : $HP"
echo "CPU sensor    : $CPU_TEMP"
echo "GPU sensor    : NVIDIA"
echo
echo "FAN CURVE"
echo "----------------------------------------"
echo "≤45°C    -> PWM 0"
echo "46-69°C  -> PWM 100"
echo "70-85°C  -> PWM 190"
echo "≥86°C    -> PWM 255 + MAX HOLD"
echo
echo "STEP UP DELAY   : $STEP_UP_DELAY seconds"
echo "STEP DOWN DELAY : $STEP_DOWN_DELAY seconds"
echo "MAX HOLD        : $MAX_HOLD_TIME seconds"
echo
echo "CTRL+C = Restore HP automatic control"

sleep 3


# ========================================
# STATE VARIABLES
# ========================================

CURRENT_PWM=-1

PENDING_PWM=-1
PENDING_START=0

MAX_HOLD=0
MAX_HOLD_START=0


# ========================================
# MAIN LOOP
# ========================================

while true; do

    CPU=$(get_cpu_temp)
    GPU=$(get_gpu_temp)

    # ------------------------------------
    # Validate readings
    # ------------------------------------

    if [ -z "$CPU" ] || [ -z "$GPU" ]; then

        printf "\033[H\033[J"

        echo "⚠️ Failed to read temperature."
        echo
        echo "CPU: ${CPU:-UNKNOWN}"
        echo "GPU: ${GPU:-UNKNOWN}"

        sleep "$CHECK_INTERVAL"
        continue

    fi


    # ------------------------------------
    # Find hottest sensor
    # ------------------------------------

    if [ "$CPU" -gt "$GPU" ]; then

        HIGHEST="$CPU"
        HOT_SOURCE="CPU"

    else

        HIGHEST="$GPU"
        HOT_SOURCE="GPU"

    fi


    NOW=$(date +%s)


    # ====================================
    # MAX HOLD LOGIC
    # ====================================

    if [ "$HIGHEST" -ge "$MAX_THRESHOLD" ]; then

        # Start MAX HOLD if not already active
        if [ "$MAX_HOLD" -eq 0 ]; then

            MAX_HOLD=1
            MAX_HOLD_START="$NOW"

            apply_pwm "$MAX_PWM"
            CURRENT_PWM="$MAX_PWM"

        fi

    fi


    # ------------------------------------
    # Handle active MAX HOLD
    # ------------------------------------

    if [ "$MAX_HOLD" -eq 1 ]; then

        ELAPSED=$((NOW - MAX_HOLD_START))
        REMAINING=$((MAX_HOLD_TIME - ELAPSED))

        if [ "$REMAINING" -lt 0 ]; then
            REMAINING=0
        fi

        # Keep requesting max PWM
        if [ "$CURRENT_PWM" -ne "$MAX_PWM" ]; then

            apply_pwm "$MAX_PWM"
            CURRENT_PWM="$MAX_PWM"

        fi


        # After 5 minutes, leave max hold
        if [ "$ELAPSED" -ge "$MAX_HOLD_TIME" ]; then

            MAX_HOLD=0

            # Reset pending timer
            PENDING_PWM=-1
            PENDING_START=0

        fi

    fi


    # ====================================
    # NORMAL FAN CURVE
    # ====================================

    TARGET_PWM=$(get_target_pwm "$HIGHEST")

    STATUS_TEXT="Fan speed stable"
    PENDING_SECONDS=0


    if [ "$MAX_HOLD" -eq 0 ]; then

        # --------------------------------
        # FIRST PWM APPLICATION
        # --------------------------------

        if [ "$CURRENT_PWM" -eq -1 ]; then

            apply_pwm "$TARGET_PWM"
            CURRENT_PWM="$TARGET_PWM"

            STATUS_TEXT="Initial fan speed applied"


        # --------------------------------
        # SPEED INCREASE
        # --------------------------------

        elif [ "$TARGET_PWM" -gt "$CURRENT_PWM" ]; then

            # MAX is immediate
            if [ "$TARGET_PWM" -eq "$MAX_PWM" ]; then

                apply_pwm "$TARGET_PWM"
                CURRENT_PWM="$TARGET_PWM"

                PENDING_PWM=-1
                PENDING_START=0

                STATUS_TEXT="🔥 Maximum cooling requested"

            else

                # New increase event
                if [ "$PENDING_PWM" -ne "$TARGET_PWM" ]; then

                    PENDING_PWM="$TARGET_PWM"
                    PENDING_START="$NOW"

                fi

                PENDING_SECONDS=$((NOW - PENDING_START))

                if [ "$PENDING_SECONDS" -ge "$STEP_UP_DELAY" ]; then

                    apply_pwm "$TARGET_PWM"
                    CURRENT_PWM="$TARGET_PWM"

                    PENDING_PWM=-1
                    PENDING_START=0

                    STATUS_TEXT="⬆ Increasing fan speed"

                else

                    REMAINING=$((STEP_UP_DELAY - PENDING_SECONDS))

                    STATUS_TEXT="Pending higher fan speed - waiting ${REMAINING}s"

                fi

            fi


        # --------------------------------
        # SPEED DECREASE
        # --------------------------------

        elif [ "$TARGET_PWM" -lt "$CURRENT_PWM" ]; then

            # New lower-speed event
            if [ "$PENDING_PWM" -ne "$TARGET_PWM" ]; then

                PENDING_PWM="$TARGET_PWM"
                PENDING_START="$NOW"

            fi

            PENDING_SECONDS=$((NOW - PENDING_START))

            if [ "$PENDING_SECONDS" -ge "$STEP_DOWN_DELAY" ]; then

                apply_pwm "$TARGET_PWM"
                CURRENT_PWM="$TARGET_PWM"

                PENDING_PWM=-1
                PENDING_START=0

                STATUS_TEXT="⬇ Lowering fan speed request applied"

            else

                REMAINING=$((STEP_DOWN_DELAY - PENDING_SECONDS))

                STATUS_TEXT="⬇ Lower temps detected - requesting slower fan RPM in ${REMAINING}s"

            fi


        # --------------------------------
        # SPEED UNCHANGED
        # --------------------------------

        else

            PENDING_PWM=-1
            PENDING_START=0

            STATUS_TEXT="Fan speed stable"

        fi

    fi


    # ====================================
    # READ FAN STATUS
    # ====================================

    MODE=$(cat "$HP/pwm1_enable" 2>/dev/null)
    READBACK_PWM=$(cat "$HP/pwm1" 2>/dev/null)

    FAN1=$(cat "$HP/fan1_input" 2>/dev/null)
    FAN2=$(cat "$HP/fan2_input" 2>/dev/null)


    # ====================================
    # DISPLAY
    # ====================================

    printf "\033[H\033[J"

    echo "========================================"
    echo "       HP OMEN FAN CURVE CONTROL"
    echo "========================================"
    echo

    echo "CPU TEMP        : $CPU°C"
    echo "GPU TEMP        : $GPU°C"
    echo "CURRENT HIGHEST : $HIGHEST°C ($HOT_SOURCE)"

    echo
    echo "MAX THRESHOLD   : ≥ $MAX_THRESHOLD°C"

    echo
    echo "MODE            : MANUAL CURVE"
    echo "TARGET PWM      : $TARGET_PWM"
    echo "CURRENT REQUEST : $CURRENT_PWM"
    echo "READBACK PWM    : $READBACK_PWM"
    echo "pwm1_enable     : $MODE"

    echo
    echo "FAN 1           : $FAN1 RPM"
    echo "FAN 2           : $FAN2 RPM"

    echo
    echo "----------------------------------------"
    echo "FAN CURVE"
    echo "----------------------------------------"
    echo "≤45°C           -> PWM 0"
    echo "46-69°C         -> PWM 100"
    echo "70-85°C         -> PWM 190"
    echo "≥86°C           -> PWM 255 + MAX HOLD"


    echo
    echo "----------------------------------------"


    # MAX HOLD DISPLAY
    if [ "$MAX_HOLD" -eq 1 ]; then

        ELAPSED=$((NOW - MAX_HOLD_START))
        REMAINING=$((MAX_HOLD_TIME - ELAPSED))

        if [ "$REMAINING" -lt 0 ]; then
            REMAINING=0
        fi

        echo "🔥 MAX HOLD ACTIVE"
        echo "MAX PWM          : $MAX_PWM"
        echo "HOLD LEFT        : ${REMAINING}s"

    else

        echo "STATUS           : $STATUS_TEXT"

        if [ "$PENDING_PWM" -ne -1 ]; then

            echo "PENDING PWM      : $PENDING_PWM"

        fi

    fi


    echo
    echo "CTRL+C = Restore HP automatic control"

    sleep "$CHECK_INTERVAL"

done
