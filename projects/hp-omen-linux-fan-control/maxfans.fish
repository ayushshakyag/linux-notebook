#!/usr/bin/env fish

# Ask for password once
sudo -v

# Clear the password prompt
clear

# Find HP hwmon controller automatically
set HP (dirname (grep -l '^hp$' /sys/class/hwmon/hwmon*/name))

if test -z "$HP"
    echo "❌ HP fan controller not found."
    exit 1
end

echo "HP controller: $HP"
sleep 1
clear

while true
    # Force manual fan mode
    if not echo 0 | sudo tee $HP/pwm1_enable >/dev/null
        echo "❌ Failed to set fan mode!"
        break
    end

    # Start timer
    set start (date +%s.%N)

    while true
        set state (cat $HP/pwm1_enable)
        set fan1 (cat $HP/fan1_input)
        set fan2 (cat $HP/fan2_input)

        set elapsed (math (date +%s.%N) - $start)

        printf "\033[H"

        printf "HP TO 2      : %.2f sec\n" $elapsed
        echo   "CURRENT STATE: $state"
        echo   "FAN1         : $fan1 RPM"
        echo   "FAN2         : $fan2 RPM"

        # HP firmware took back control
        if test "$state" = "2"
            break
        end

        sleep 0.2
    end
end
