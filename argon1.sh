#!/usr/bin/env bash

# Check if the user running the script is root
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] ERROR: You need to be root."
  exit 1
fi

argon_create_file() {
    if [ -f $1 ]; then
        sudo rm $1
    fi
    sudo touch $1
    sudo chmod 666 $1
}

argon_check_pkg() {
    RESULT=$(dpkg-query -W -f='${Status}\n' "$1" 2> /dev/null | grep "installed")

    if [ "" == "$RESULT" ]; then
        echo "NG"
    else
        echo "OK"
    fi
}

pkglist=(python3-rpi.gpio python3-smbus i2c-tools)
for curpkg in ${pkglist[@]}; do
    sudo apt-get install -y $curpkg
    RESULT=$(argon_check_pkg "$curpkg")
    if [ "NG" == "$RESULT" ]
    then
        echo "********************************************************************"
        echo "Please also connect device to the internet and restart installation."
        echo "********************************************************************"
        exit
    fi
done

daemonname="argononed"
powerbuttonscript="/usr/bin/${daemonname}.py"
shutdownscript="/lib/systemd/system-shutdown/${daemonname}-poweroff.py"
daemonconfigfile="/etc/${daemonname}.conf"
configscript="/usr/bin/argonone-config"
removescript="/usr/bin/argonone-uninstall"
daemonfanservice="/lib/systemd/system/${daemonname}.service"

#sudo raspi-config nonint do_i2c 0
#sudo raspi-config nonint do_serial 0

if [ ! -f "${daemonconfigfile}" ]; then
    # Generate config file for fan speed
    cat <<'EOM' > "${daemonconfigfile}"
#
# Argon One Fan Configuration
#
# List below the temperature (Celsius) and fan speed (in percent) pairs
# Use the following form:
# min.temperature=speed
#
# Defaults; 10% fan speed when >= 55C, 55% fan speed when >= 60C, 100% fan speed when >= 65C
# 55=10
# 60=55
# 65=100
#
# Always on example, fan will always run at 100%
# 1=100
#
# Type the following at the command line for changes to take effect:
# sudo systemctl restart argononed.service
#
# Start below:
55=10
60=55
65=100
EOM
    chmod 644 "${daemonconfigfile}"
fi

# Generate script that runs every shutdown event
cat <<'EOM' > "${shutdownscript}"
#!/usr/bin/python3
import sys
import smbus
import RPi.GPIO as GPIO
rev = GPIO.RPI_REVISION
if rev == 2 or rev == 3:
    bus = smbus.SMBus(1)
else:
    bus = smbus.SMBus(0)
if len(sys.argv)>1:
    bus.write_byte(0x1a,0)
    if sys.argv[1] == "poweroff" or sys.argv[1] == "halt":
        try:
            bus.write_byte(0x1a,0xFF)
        except:
            rev=0
EOM
chmod 755 "${shutdownscript}"

# Generate script to monitor shutdown button
cat <<'EOM' > "${powerbuttonscript}"
#!/usr/bin/python3
import smbus
import RPi.GPIO as GPIO
import os
import time
from threading import Thread
rev = GPIO.RPI_REVISION
if rev == 2 or rev == 3:
    bus = smbus.SMBus(1)
else:
    bus = smbus.SMBus(0)
GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)
shutdown_pin=4
GPIO.setup(shutdown_pin, GPIO.IN,  pull_up_down=GPIO.PUD_DOWN)

def shutdown_check():
    while True:
        pulsetime = 1
        GPIO.wait_for_edge(shutdown_pin, GPIO.RISING)
        time.sleep(0.01)
        while GPIO.input(shutdown_pin) == GPIO.HIGH:
            time.sleep(0.01)
            pulsetime += 1
        if pulsetime >=2 and pulsetime <=3:
            os.system("reboot")
        elif pulsetime >=4 and pulsetime <=5:
            os.system("shutdown now -h")

def get_fanspeed(tempval, configlist):
    for curconfig in configlist:
        curpair = curconfig.split("=")
        tempcfg = float(curpair[0])
        fancfg = int(float(curpair[1]))
        if tempval >= tempcfg:
            return fancfg
    return 0

def load_config(fname):
    newconfig = []
    try:
        with open(fname, "r") as fp:
            for curline in fp:
                if not curline:
                    continue
                tmpline = curline.strip()
                if not tmpline:
                    continue
                if tmpline[0] == "#":
                    continue
                tmppair = tmpline.split("=")
                if len(tmppair) != 2:
                    continue
                tempval = 0
                fanval = 0
                try:
                    tempval = float(tmppair[0])
                    if tempval < 0 or tempval > 100:
                        continue
                except:
                    continue
                try:
                    fanval = int(float(tmppair[1]))
                    if fanval < 0 or fanval > 100:
                        continue
                except:
                    continue
                newconfig.append( "{:5.1f}={}".format(tempval,fanval))
        if len(newconfig) > 0:
            newconfig.sort(reverse=True)
    except:
        return []
    return newconfig

def temp_check():
    fanconfig = ["65=100", "60=55", "55=10"]
    tmpconfig = load_config("'$daemonconfigfile'")
    if len(tmpconfig) > 0:
        fanconfig = tmpconfig
    address=0x1a
    prevblock=0
    while True:
        temp = os.popen("cat /sys/class/thermal/thermal_zone0/temp").readline()
        val = float(int(temp)/1000)
        block = get_fanspeed(val, fanconfig)
        if block < prevblock:
            time.sleep(30)
        prevblock = block
        try:
            bus.write_byte(address,block)
        except IOError:
            temp=""
        time.sleep(30)

try:
    t1 = Thread(target = shutdown_check)
    t2 = Thread(target = temp_check)
    t1.start()
    t2.start()
except:
    t1.stop()
    t2.stop()
    GPIO.cleanup()
EOM
chmod 755 "${powerbuttonscript}"

cat <<"EOM" > "${daemonfanservice}"
[Unit]
Description=Argon One Fan and Button Service
After=multi-user.target
[Service]
Type=simple
Restart=always
RemainAfterExit=true
ExecStart=${powerbuttonscript}
[Install]
WantedBy=multi-user.target
EOM
chmod 644 "${daemonfanservice}"

# Uninstall Script
cat <<'EOM' > "${removescript}"
#!/bin/bash
echo "-------------------------"
echo "Argon One Uninstall Tool"
echo "-------------------------"
echo -n "Press Y to continue:"
read -n 1 confirm
echo
if [ "$confirm" = "y" ]; then
    confirm="Y"
fi

if [ "$confirm" != "Y" ]; then
    echo "Cancelled"
    exit
fi

if [ -f '$powerbuttonscript' ]; then
    sudo systemctl stop '$daemonname'.service
    sudo systemctl disable '$daemonname'.service
    sudo /usr/bin/python3 '$shutdownscript' uninstall
    sudo rm '$powerbuttonscript >> $removescript
    sudo rm '$shutdownscript >> $removescript
    sudo rm '$removescript >> $removescript
    echo "Removed Argon One Services."
    echo "Cleanup will complete after restarting the device."
fi
EOM
chmod 755 "${removescript}"



sudo systemctl daemon-reload
sudo systemctl enable $daemonname.service
sudo systemctl start $daemonname.service

echo "***************************"
echo "Argon One Setup Completed."
echo "***************************"
echo 
echo Use 'argonone-config' to configure fan
echo Use 'argonone-uninstall' to uninstall
echo