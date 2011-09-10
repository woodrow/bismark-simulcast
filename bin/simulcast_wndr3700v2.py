#!/usr/bin/python2.7

import multiprocessing
import subprocess
import os
import time
import curses
import math
import argparse

# local module
import netaddr

def router_flasher_worker(status_q, fw_path, pre_ip, post_ip, worker_id):
    flash_proc = subprocess.Popen(('python wndr3700v2_factory_upgrade.py '
        '%s %s %s' % (fw_path, str(pre_ip), str(post_ip))),
        shell=True,
        stdout=subprocess.PIPE,
        bufsize=1)

    # get output as it's updated
    next_line = ""
    while True:
        new_str = os.read(flash_proc.stdout.fileno(), 1000)
        parts = new_str.partition('\n')
        while parts != ('', '', ''):
            next_line += parts[0]
            if parts[1] == '\n':
                status_q.put((worker_id, next_line))
                next_line = ''
                parts = parts[2].partition('\n')
        time.sleep(0.5)

def display_worker(status_q, num_workers):
    winobj = curses.initscr()
    try:
        start_x = int(math.ceil(math.log10(num_workers+1))) + 1
        for i in xrange(num_workers):
            winobj.addstr(i, 0, ("{:>" + str(start_x-1) + "}").format(str(i+1)))
        winobj.refresh()
        counter = 1
        while True:
            update = status_q.get()
            winobj.addstr(update[0], start_x, update[1] + (" (%d)" % counter))
            winobj.refresh()
            counter += 1
    except KeyboardInterrupt:
        curses.endwin()

def router_flasher_commander(
    fw_path, start_pre_ip, start_post_ip, num_workers):

    status_q = multiprocessing.Queue()

    disp_worker = multiprocessing.Process(
        target=display_worker,
        args=(status_q, num_workers))
    disp_worker.start()

    flash_workers = []
    for i in xrange(num_workers):
        flash_worker = multiprocessing.Process(
            target=router_flasher_worker,
            args=(status_q, fw_path, start_pre_ip+i, start_post_ip+i, i))
        flash_workers.append(flash_worker)
        flash_worker.start()

def main():
    # Parse commmand-line arguments
    aparser = argparse.ArgumentParser(
        description=("Upgrade many Netgear WNDR3700v2's factory firmware "
            "images simultaneously. Be careful -- an errant CTRL-c will kill "
            "the upgrade process mid-way."))
    aparser.add_argument(
        'firmware_file',
        type=argparse.FileType('rb'),
        metavar='FIRMWARE_PATH',
        help='the path to the firmware image (.img)')
    aparser.add_argument(
        'factory_prefix',
        type=verify_ip_net,
        metavar='FACTORY_IP_PREFIX',
        help='the IP address prefix of the routers to flash')
    aparser.add_argument(
        'flashed_prefix',
        type=verify_ip_net,
        metavar='FLASHED_IP_PREFIX',
        help='the IP address prefix the routers will occupy once flashed')
    aparser.add_argument(
        'num_workers',
        type=int,
        metavar='NUM_WORKERS',
        help='the number of flashing processes to be running in parallel')
    args = aparser.parse_args()
    if (len(args.factory_prefix)-2-1 < args.num_workers or
        len(args.flashed_prefix)-2-1 < args.num_workers):
        raise Exception("You have specified more workers than possible IP "
            "addresses in the prefix")
    if args.num_workers > 47:
        raise Exception("This must be a mistake. Try fewer NUM_WORKERS.")
    router_flasher_commander(
        args.firmware_file.name,
        args.factory_prefix.ip+1,
        args.flashed_prefix.ip+1,
        args.num_workers)

def verify_ip_net(s):
    prefix = None
    try:
        prefix = netaddr.IPNetwork(s)
        if '/' not in s:
            octets = [int(x) for x in s.split('.')]
            if sum(octets[1:]) == 0:
                prefix.prefixlen = 8
            elif sum(octets[2:]) == 0:
                prefix.prefixlen = 16
            elif octets[3] == 0:
                prefix.prefixlen = 24
            else:
                raise Exception()
    except Exception:
        raise argparse.ArgumentTypeError()
    return prefix

if __name__ == '__main__':
    main()
