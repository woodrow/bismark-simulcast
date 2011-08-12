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
FACTORY_SUBNET="192.168.2.0/24"
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

# clear arp cache
ip neighbor flush nud permanent

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
    ifconfig $VIF down
    ifconfig $VIF up
    ifconfig $VIF 192.168.2.254 netmask 255.255.255.255 # this is a magic number

    # set up egress (root) qdisc
    tc qdisc del dev $VIF root > /dev/null
    tc qdisc add dev $VIF root handle $VLAN_ID: htb

    # set up ingress qdisc
    tc qdisc del dev $VIF ingress > /dev/null
    tc qdisc add dev $VIF ingress

    # TODO: CONSIDER USING MULTIPLE ROUTING TABLES FOR THE DIFFERENT ADDRESS
    #       SCHEMES/RANGES INVOLVED
    #       ALSO, s/ifconfig/ip addr/
    for SUBNET in $FACTORY_SUBNET $BISMARK_SUBNET
    do

        OCTETS=$(echo $SUBNET | grep -o "\([0-9]\+\.\)\{2\}[0-9]\+")
        VIF_ADDR=$OCTETS.$i
        IF_ADDR=$OCTETS.254
        GW_ADDR=$OCTETS.1

        # move ifconfig stuff here...
        # have subnets come from an array, and iterate through them
        # put into separate routing tables for each subnet
        # don't forget to construct `ip rule` rules.

        ip route add $VIF_ADDR/32 dev $VIF src $IF_ADDR protocol static \
            metric 20

        # rewrite outgoing ARP
        VIF_ADDR_HEX=$(printf '%02x' ${VIF_ADDR//./ })
        GW_ADDR_HEX=$(printf '%02x' ${GW_ADDR//./ })
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol arp \
            u32 \
            match u32 0x$VIF_ADDR_HEX 0xffffffff at 24 \
            action pedit \
            munge offset 24 u32 set 0x$GW_ADDR_HEX \
            > /dev/null

        # rewrite incoming ARP
        VIF_ADDR_UHEX=$(echo -n $VIF_ADDR_HEX | head -c 4)
        VIF_ADDR_LHEX=$(echo -n $VIF_ADDR_HEX | tail -c 4)
        GW_ADDR_UHEX=$(echo -n $GW_ADDR_HEX | head -c 4)
        GW_ADDR_LHEX=$(echo -n $GW_ADDR_HEX | tail -c 4)
        tc filter add dev $VIF parent ffff: pref $[++IPROUTE_PRIO] \
            protocol arp \
            u32 \
            match u16 0x$GW_ADDR_UHEX 0xffff at 14 \
            match u16 0x$GW_ADDR_LHEX 0xffff at 16 \
            action pedit \
            munge offset 14 u16 set 0x$VIF_ADDR_UHEX \
            munge offset 16 u16 set 0x$VIF_ADDR_LHEX \
            > /dev/null

        # Rewrite source address of outgoing packets
        # TODO: this may not be necessary -- test?
        # action nat egress = rewrite src addr
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip dst $VIF_ADDR \
            action nat egress 0.0.0.0/0 $IF_ADDR \
            continue
        # action nat egress $HOST_BRIDGE_IF_ADDR $OCTETS.254 \
        # this should probably be action nat egress 0.0.0.0/0 ..., but this
        # is a work around

        # Rewrite destination address of outgoing packets
        # action nat ingress = rewrite dst addr
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip dst $VIF_ADDR \
            action nat ingress $VIF_ADDR $GW_ADDR \
            pass

        ## Rewrite destination address of incoming packets
        ## action nat ingress = rewrite dst addr
        #tc filter add dev $VIF parent ffff: pref $[++IPROUTE_PRIO] \
        #protocol ip \
        #u32 match ip src $GW_ADDR \
        #action nat ingress $IF_ADDR $HOST_BRIDGE_IF_ADDR \
        #continue
        ## this could probably be action nat ingress 0.0.0.0/0 ..., but this
        ## is a work around

        # Rewrite source address of incoming packets
        # action nat egress = rewrite src addr
        tc filter add dev $VIF parent ffff: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip src $GW_ADDR \
            action nat egress $GW_ADDR $VIF_ADDR \
            pass
    done
done

ip route flush cache
