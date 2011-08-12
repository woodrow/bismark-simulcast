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
    ifconfig $VIF down
    ifconfig $VIF up
    ifconfig $VIF 192.168.2.254 netmask 255.255.255.255 # this is a magic number

    # set up egress (root) qdisc
    tc qdisc del dev $VIF root > /dev/null
    tc qdisc add dev $VIF root handle $VLAN_ID: htb

    # set up ingress qdisc
    tc qdisc del dev $VIF ingress > /dev/null
    tc qdisc add dev $VIF ingress

    for SUBNET in $FACTORY_SUBNET $BISMARK_SUBNET
    do

        OCTETS=$(echo $SUBNET | grep -o "\([0-9]\+\.\)\{2\}[0-9]\+")

        ip route add $OCTETS.$i/32 protocol static metric 20 dev $VIF
        #ip neighbor add $OCTETS.$i dev $VIF \
        #    lladdr ff:ff:ff:ff:ff:ff nud permanent > /dev/null
        #if [ $? -ne 0 ]
        #then
        #    ip neighbor change $OCTETS.$i dev $VIF \
        #        lladdr ff:ff:ff:ff:ff:ff nud permanent
        #fi

        # TODO: ARP is still a problem -- the stack does an ARP request on the
        # un-rewritten address
        # printf '%02X' ${IP_ADDR//./ };
        #
        # rewrite outgoing ARP
        VIF_ADDR=$OCTETS.$i
        VIF_ADDR_HEX=$(printf '%02x' ${VIF_ADDR//./ })
        GW_ADDR=$OCTETS.1
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

        # TODO: UGGH, MASQUERADING IS STILL NECESSARY, or at least i need to
        # configure interface addresses, else netgear box arps :(
        # also, be careful with ifconfig $VIF up and dhclient, as these change
        # the routing table, etc.

        # Rewrite source address of outgoing packets
        # action nat egress = rewrite src addr
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip dst $OCTETS.$i \
            action nat egress 0.0.0.0/0 $OCTETS.254 \
            continue
        # action nat egress $HOST_BRIDGE_IF_ADDR $OCTETS.254 \
        # this should probably be action nat egress 0.0.0.0/0 ..., but this
        # is a work around

        # Rewrite destination address of outgoing packets (NOTE 1)
        # action nat ingress = rewrite dst addr
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip dst $OCTETS.$i \
            action nat ingress $OCTETS.$i $OCTETS.1 \
            pass

        ## Rewrite destination address of incoming packets
        ## action nat ingress = rewrite dst addr
        #tc filter add dev $VIF parent ffff: pref $[++IPROUTE_PRIO] \
        #protocol ip \
        #u32 match ip src $OCTETS.1 \
        #action nat ingress $OCTETS.254 $HOST_BRIDGE_IF_ADDR \
        #continue
        ## this could probably be action nat ingress 0.0.0.0/0 ..., but this
        ## is a work around

        # Rewrite source address of incoming packets
        # action nat egress = rewrite src addr
        tc filter add dev $VIF parent ffff: pref $[++IPROUTE_PRIO] \
            protocol ip \
            u32 match ip src $OCTETS.1 \
            action nat egress $OCTETS.1 $OCTETS.$i \
            pass

        # TODO: TURN THIS ON LATER!
        # TODO UPDATE: this is no longer necessary because i'm just
        # bruteforcing my address as 192.168.x.101
        #dhclient -nw $VIF
        ## TODO: what happens when we do ifconfig ... down and ifconfig ... up
        ## (from a client/flashing application) on a dhclient-daemonized
        ## interface?
    done
done

ip route flush cache
