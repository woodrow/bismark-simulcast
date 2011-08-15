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

#-------------------------------------------------------------------------------
# CONFIGURATION

# NUM_VLANS is the number of VLANs you wish to use for flashing. For an N-port
#           switch, this should be set to N-1 (i.e. NUM_VLANS=47 for a 48-port
#           switch).
NUM_VLANS=12

# SUBNETS is an array of networks that the devices being programmed will be
#         expected to occupy. This will normally be two ranges for flashing
#         from the Netgear factory firmware to the Bismark/Cerowrt firmware --
#         one range for each configuration based on the range configured by the
#         factory in each case. If simulcast is being used to communicate with
#         routers that will not undergo a configuration change, this can be
#         reduced to a single network representing the router's actual
#         configuration.
SUBNETS=("192.168.2.0/24" "192.168.42.0/24")

# HOST_BRIDGE_IF_NAME is the name of the device that is bridged to the ethernet
#                     port on the host that connects to the trunk port on the
#                     switch. This device name will depend on the configuration
#                     of your virtual machine. In the case of VirtualBox, be
#                     sure to select a non-Intel adaptor to emulate, as the
#                     Intel adaptor is known to strip VLAN tags
#              (http://humbledown.org/virtualbox-intel-vlan-tag-stripping.xhtml)
HOST_BRIDGE_IF_NAME="eth2"

#-------------------------------------------------------------------------------

# configure interface bridged to the host's ethernet port
ifconfig $HOST_BRIDGE_IF_NAME up

# enable forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# enable vlans
modprobe 8021q

# enable iptables NAT
modprobe iptable_nat

# clear iptables
iptables -t nat --flush

# clear routing tables
for TABLENUM in $(ip route show table all | grep -o "table [0-9]\+" |
    grep -o "[0-9]\+" | sort | uniq)
do
    ip route flush proto static table $TABLENUM
done

# clear policy routing table
ip rule flush
ip rule add from all lookup main pref 32766
ip rule add from all lookup default pref 32767

# clear ARP cache
ip neighbor flush nud permanent

#-------------------------------------------------------------------------------
# Configure VLANs
#-------------------------------------------------------------------------------

for ((i=1; i<=$NUM_VLANS; i++))
do
    VLAN_ID=$[$i+100]  # the VLAN tag
    VIF=$HOST_BRIDGE_IF_NAME.$VLAN_ID

    # Create each VLAN interface and bring it up
    if [ ! -e /proc/net/vlan/$VIF ]
    then
        vconfig add $HOST_BRIDGE_IF_NAME $VLAN_ID > /dev/null
    fi
    ifconfig $VIF down
    ifconfig $VIF up
    ip addr flush dev $VIF

    # Set up egress (root) qdisc
    tc qdisc del dev $VIF root &> /dev/null
    tc qdisc add dev $VIF root handle $VLAN_ID: htb

    # Set up ingress qdisc
    tc qdisc del dev $VIF ingress &> /dev/null
    tc qdisc add dev $VIF ingress
done

#-------------------------------------------------------------------------------
# Configure routing
#-------------------------------------------------------------------------------

# This is a unique preference/priority value for the various tc rules
IPROUTE_PRIO=100

for ((sn=0; sn < ${#SUBNETS[*]}; sn++))
do
    TABLE=$[$sn+1]  # the routing table identifier
    SUBNET=${SUBNETS[$sn]}
    # TODO: OCTETS is currently hard-coded for a /24
    OCTETS=$(echo $SUBNET | grep -o "\([0-9]\+\.\)\{2\}[0-9]\+")

    ip rule add to $SUBNET table $TABLE

    for ((i=1; i<=$NUM_VLANS; i++))
    do
        VLAN_ID=$[$i+100]
        VIF=$HOST_BRIDGE_IF_NAME.$VLAN_ID
        VIF_ADDR=$OCTETS.$i
        IF_ADDR=$OCTETS.254
        GW_ADDR=$OCTETS.1

        # Add generic on-subnet interface address (IF_ADDR) to interface.
        # This will appear as the source address for ARP requests and IP
        # packets directed at the device being flashed.
        ip addr add $IF_ADDR/32 dev $VIF label $VIF:$TABLE

        # Add route to the device-specific on-subnet address (VIF_ADDR) via the
        # appropriate VLAN interface and with the appropriate source address
        # on that interface.
        ip route add $VIF_ADDR/32 dev $VIF src $IF_ADDR \
            protocol static metric 20 table $TABLE

        # Rewrite outgoing ARP to set requested (who-has) address to
        # the gateway address
        VIF_ADDR_HEX=$(printf '%02x' ${VIF_ADDR//./ })
        GW_ADDR_HEX=$(printf '%02x' ${GW_ADDR//./ })
        tc filter add dev $VIF parent $VLAN_ID: pref $[++IPROUTE_PRIO] \
            protocol arp \
            u32 \
            match u32 0x$VIF_ADDR_HEX 0xffffffff at 24 \
            action pedit \
            munge offset 24 u32 set 0x$GW_ADDR_HEX \
            > /dev/null

        # Rewrite incoming ARP to set reply address from the gateway to
        # the VIF's address
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

# Flush the routing cache to ensure all changes are active
ip route flush cache
