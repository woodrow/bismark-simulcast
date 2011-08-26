#!/bin/bash

#-------------------------------------------------------------------------------
# This script should set up a vanilla Ubuntu Server VM installed from a CD
# image to allow it to be used for bismark-simulcast.
#
# This script must be run as root.
#
# This has not been tested -- USE AT YOUR OWN RISK, preferably on a virtual
# machine.
#
# Speaking of virtual machines, this has been tested out on a VirtualBox OSE vm
# configured with the following interfaces:
#
#   eth0: NAT-ed to host OS (for Internet access) eth1: bridged to host's
#   vboxnet0 (host-only, for SSH) eth2: bridged to host's ethernet port
#-------------------------------------------------------------------------------

# set up vbox interfaces
## eth0 is NAT-ed to host OS for Internet
echo "auto eth0" >> /etc/network/interfaces
echo "iface eth0 inet dhcp" >> /etc/network/interfaces
echo "    metric 20" >> /etc/network/interfaces
## eth1 is connected to vboxnet0 (host-only for SSH)
echo "auto eth1" >> /etc/network/interfaces
echo "iface eth1 inet dhcp" >> /etc/network/interfaces
echo "    metric 20" >> /etc/network/interfaces
## eth2 is bridged to the host's ethernet port

## install packages
#apt-get install vlan
#apt-get install ifmetric
#apt-get install fping
