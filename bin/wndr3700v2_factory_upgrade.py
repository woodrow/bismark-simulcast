#!/usr/bin/python2.7

import urllib2
import sys
import argparse
import subprocess
import MultipartPostHandler
import time
import re
import os

INCLUDE_COUNTDOWN = False
APPROVED_FIRMWARE_VERSIONS = [
    'V1.0.0.6NA',
    'V1.0.0.10NA',
    ]

# make stdout unbuffered
unbuf_stdout = os.fdopen(sys.stdout.fileno(), 'w', 0)
sys.stdout = unbuf_stdout

def main():
    # Parse commmand-line arguments
    aparser = argparse.ArgumentParser(
        description="Upgrade a Netgear WNDR3700v2's firmware")
    aparser.add_argument(
        'firmware_file',
        type=argparse.FileType('rb'),
        metavar='FIRMWARE_PATH',
        help='the path to the firmware image (.img)')
    aparser.add_argument(
        'factory_ip',
        type=verify_ipv4_str,
        metavar='FACTORY_IP_ADDR',
        help='the IP address of the router to flash')
    aparser.add_argument(
        'flashed_ip',
        type=verify_ipv4_str,
        metavar='FLASHED_IP_ADDR',
        help='the IP address the router will have once flashed')
    args = aparser.parse_args()

    # See if fping exists
    if subprocess.call("fping -v > /dev/null 2>&1", shell=True) > 0:
        raise Exception("This tool relies on 'fping'. Please install it from "
            "your package manager and try it again.")

    # See if sshpass exists
    if subprocess.call("sshpass -V > /dev/null 2>&1", shell=True) > 0:
        raise Exception("This tool relies on 'sshpass'. Please install it from "
            "your package manager and try it again.")

    # Wait for the device to be on the network
    while subprocess.call("fping -a %s > /dev/null 2>&1" % args.factory_ip,
        shell=True) > 0:
        print("Waiting for router %s..." % args.factory_ip)

    # Check version
    while True:
        try:
            response = urllib2.urlopen(
                url='http://%s/currentsetting.htm' % args.factory_ip,
                timeout=2)
        except urllib2.URLError:
            print("Waiting for router %s..." % args.factory_ip)
        else:
            break
    if response.code != 200:
        raise Exception(("GET http://%s/currentsetting.htm received a HTTP "
            "status %d response.") % (args.factory_ip, response.code))
    curr_config = dict(
        [(x.split('=')[0], x.split('=')[1]) for x in
            response.readlines()[0].split()])
    if curr_config['Firmware'] not in APPROVED_FIRMWARE_VERSIONS:
        raise Exception(("The current firmware on the router (version %s) has "
            "not been tested with this tool. Try it by hand and then add it "
            "to the APPROVED_FIRMWARE_VERSIONS list.") %
            curr_config['Firmware'])

    # Set up HTTP Basic authentication manager
    pwmgr = urllib2.HTTPPasswordMgrWithDefaultRealm()
    pwmgr.add_password(None, args.factory_ip, 'admin', 'password')
    auth_handler = urllib2.HTTPBasicAuthHandler(pwmgr)
    opener = urllib2.build_opener(MultipartPostHandler.MultipartPostHandler,
        auth_handler)

    # POST the firmware to the router
    print("Uploading firmware to router %s" % args.factory_ip)
    form_data = {
        'Upgrade': 'Upload',
        'mtenFWUpload': args.firmware_file
        }
    response = opener.open('http://%s/upgrade_check.cgi' % args.factory_ip,
        data=form_data)
    if response.code != 200:
        raise Exception(("POST http://%s/upgrade_check.cgi received a HTTP "
            "status %d response.") % (args.factory_ip, response.code))

    # Wait the prescribed 1 second
    time.sleep(1)

    # check to see that the firmware has registered appropriately
    response = opener.open('http://%s/UPG_version.htm' % args.factory_ip)
    lines = response.readlines()
    if response.code != 200:
        raise Exception(("GET http://%s/UPG_version.cgi received a HTTP "
            "status %d response.") % (args.factory_ip, response.code))
    if not re.search('var module_name=\"WNDR3700v2\"', ''.join(lines)):
        raise Exception("Firmware module name didn't seem to register with "
            "router.")
    # ---------------------------------
    # var module_name="WNDR3700v2";
    # var new_version="V1.0.0.10";
    # var new_region="";
    # var openSource = "0"
    # ---------------------------------
    # var module_name="WNDR3700v2";
    # var new_version="VOpenWrt.r27762";
    # var new_region="";
    # var openSource = "0"
    # ---------------------------------

    # POST upgrade confirmation
    print("Initiating upgrade on router %s" % args.factory_ip)
    response = opener.open('http://%s/upgrade.cgi' % args.factory_ip,
        data={'upgrade_yes_no': '1'})
    if response.code != 200:
        raise Exception(("POST http://%s/upgrade.cgi received a HTTP "
            "status %d response.") % (args.factory_ip, response.code))

    # GET /UPG_process.htm; check status until it reaches 1100
    var_status = 1000
    while var_status < 1100:
        try:
            response = opener.open(('http://%s/UPG_process.htm' %
                args.factory_ip), timeout=2)
        except urllib2.URLError:
            break
        lines = response.readlines()
        if response.code != 200:
            raise Exception(("GET http://%s/UPG_version.cgi received a HTTP "
                "status %d response.") % (args.factory_ip, response.code))
        var_status = int(re.search('var status = (\d+);',
            ''.join(lines)).group(1))
        print("Upgrade %d%% complete" % (var_status - 1000))
        time.sleep(5)

    # Wait for router to restart
    print("Upgrade complete. Router should now reboot.")
    if INCLUDE_COUNTDOWN:
        print("Starting 2-minute countdown.")
        time_remaining = 120
        sleep_interval = 10
        while time_remaining > 0:
            print("%s seconds remaining..." % time_remaining)
            time.sleep(sleep_interval)
            time_remaining -= sleep_interval

    # Wait for the device to appear again under its new IP address
    while subprocess.call("fping -a %s &> /dev/null" % args.flashed_ip,
        shell=True) > 0:
        print("Waiting for router %s ECHO_REPLY..." % args.flashed_ip)

    # Wait for the web interface to come up
    while True:
        try:
            response = urllib2.urlopen(
                url='http://%s' % args.flashed_ip,
                timeout=2)
        except urllib2.HTTPError:
            break
        except urllib2.URLError:
            print("Waiting for router %s web interface..." % args.flashed_ip)
            time.sleep(5)
        else:
            break

# THIS DOESN'T WORK SO WELL RIGHT NOW
#
#    # Get LAN interface MAC addresses
#    output = subprocess.check_output(('sshpass -p bismark123 '
#        'ssh -o StrictHostKeyChecking=no '
#        'root@%s /usr/sbin/ip link show eth0') % args.flashed_ip, shell=True)
#    lan_mac = re.search("link/ether ([^ ]*) ", output).groups()[0]

    # Done
    print("Upgrade of router %s complete." % args.flashed_ip)
    time.sleep(1000)


def verify_ipv4_str(s):
    try:
        octets = s.split('.')
        if type(octets) == list and len(octets) == 4:
            for octet in octets:
                if not (0 <= int(octet) <= 255):
                    raise StandardError()
            return s
    except StandardError:
        pass
    raise argparse.ArgumentTypeError()


if __name__ == '__main__':
    main()







# changing state:
#   - call change_state(STATE_ENUM_TYPE)
#       - change_state updates state locally and puts an update message into
#         the queue to the master
