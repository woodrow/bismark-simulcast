#!/bin/bash

#-------------------------------------------------------------------------------
# This script should configure a previously setup (using setup.sh) Debian VM to
# run bismark-simulcast. To the best of my knowledge, none of these settings
# are persistent, and so this script must be run after a reboot.
#
# This script must be run as root.
#
# This has not been tested -- USE AT YOUR OWN RISK, preferably on a virtual
# machine.
#
# NOTE re earlier problems with missing tags:
#     http://humbledown.org/virtualbox-intel-vlan-tag-stripping.xhtml
#
#-------------------------------------------------------------------------------

NUM_VLANS=2
FACTORY_SUBNET="192.168.1.0/24"
BISMARK_SUBNET="192.168.42.0/24"
HOST_BRIDGE_IF_NAME="eth2"
HOST_BRIDGE_IF_ADDR="192.168.254.1"

# configure eth2
## eth2 is bridged to the host's ethernet port
ifconfig $HOST_BRIDGE_IF_NAME up
ifconfig $HOST_BRIDGE_IF_NAME $HOST_BRIDGE_IF_ADDR

# enable forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# enable vlans
modprobe 8021q

# enable iptables NAT
modprobe iptable_nat

# clear iptables
iptables -t nat --flush

# clear routing table
ip route flush proto static
ip neighbor flush nud permanent

##------------------------------------------------------------------------------
## configure routing table: add route for subnet, even though we won't actually
## use the route (this is to make sure the host knows there's a route).
#    ip route add $SUBNET metric 10 dev $HOST_BRIDGE_IF_NAME

#-------------------------------------------------------------------------------
# iptables rules to be added before interface-specific rules -- first rules in
#   the chain

    ## TODO: is this necessary? or should the masquerade handle this?
    #iptables -A PREROUTING -t nat -s $SUBNET \
    #    -j DNAT --to-destination $HOST_BRIDGE_IF_ADDR

#-------------------------------------------------------------------------------
# configure vlans
IPROUTE_PRIO=100
for ((i=1; i<=$NUM_VLANS; i++))
do
    VLAN_ID=$[$i+100]
    VIF=$HOST_BRIDGE_IF_NAME.$VLAN_ID
    if [ ! -e /proc/net/vlan/$VIF ]
    then
        vconfig add $HOST_BRIDGE_IF_NAME $VLAN_ID
    fi
    ifconfig $VIF up

    for SUBNET in $FACTORY_SUBNET $BISMARK_SUBNET
    do

        OCTETS=$(echo $SUBNET | grep -o "\([0-9]\+\.\)\{2\}[0-9]\+")

        ip route add $OCTETS.$i/32 protocol static metric 20 dev $VIF
        ip neighbor add $OCTETS.$i dev $VIF \
            lladdr ff:ff:ff:ff:ff:ff nud permanent > /dev/null
        if [ $? -ne 0 ]
        then
            ip neighbor change $OCTETS.$i dev $VIF \
                lladdr ff:ff:ff:ff:ff:ff nud permanent
        fi

        ## Rewrite source to masquerade
        #iptables -t nat -A POSTROUTING \
        #    -o $VIF \
        #    -j MASQUERADE
        ## ...or...
        # SNAT
        iptables -t nat -A POSTROUTING \
            -o $VIF \
            -s $HOST_BRIDGE_IF_ADDR \
            -j SNAT --to-source $OCTETS.101

        # Rewrite destination to match gateway address
        iptables -t nat -A OUTPUT \
            -o $VIF \
            -d $OCTETS.$i \
            -j DNAT --to-destination $OCTETS.1

        # Redirect incoming traffic to proper address
        iptables -t nat -A PREROUTING \
            -i $VIF \
            -d $SUBNET \
            -j DNAT --to-destination $HOST_BRIDGE_IF_ADDR

        ## need to do something about this -- this doesn't work
        #iptables -A POSTROUTING -t nat \
        #    -i $VIF \
        #    -j SNAT \
        #    --to-source $OCTETS.$i

        ## this isn't valid syntax (SNAT only belongs in POSTROUTING), but is
        ## something I was worried about :P
        #iptables -A PREROUTING -t nat -i $VIF \
        #    -j SNAT --to-source $FACTORY_OCTETS.$i

        # TODO: TURN THIS ON LATER!
        #dhclient -nw $VIF
        ## TODO: what happens when we do ifconfig ... down and ifconfig ... up
        ## (from a client/flashing application) on a dhclient-daemonized
        ## interface?
    done
done

ip route flush cache
